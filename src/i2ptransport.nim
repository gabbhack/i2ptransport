when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/strformat
import chronos, chronicles, strutils
import stew/[
  byteutils,
  results,
  objects
]
import libp2p/[
  multicodec,
  switch,
  builders,
  multiaddress
]
import libp2p/stream/[
  lpstream,
  connection,
  chronosstream
]
import libp2p/transports/[
  transport,
  tcptransport
]
import libp2p/upgrademngrs/upgrade
import sam_protocol as sam


type
  I2PSessionSettings = object
    nickname: string
    inboundLength: int
    outboundLength: int
    inboundQuantity: int
    outboundQuantity: int

  I2PTransport* = ref object of Transport
    controlSessionConnection: Connection
    streamForwardConnection: Connection
    transportAddress: TransportAddress
    tcpTransport: TcpTransport
    settings: I2PSessionSettings

  TransportStartError* = object of transport.TransportError

  I2PError* = object of CatchableError


const
  I2P* = mapAnd(DNS, mapEq("http"))
  SamMinVersion = "3.1"
  SamMaxVersion = "3.1"

proc init*(
  Self: typedesc[I2PSessionSettings],
  nickname: string,
  inboundLength = 3,
  outboindLength = 3,
  inboundQuantity = 5,
  outboundQuantity = 5,
): Self {.public.} =
  Self(
    nickname: nickname,
    inboundLength: inboundLength,
    outboindLength: outboindLength,
    inboundQuantity: inboundQuantity,
    outboundQuantity: outboundQuantity,
  )

proc new*(
  Self: typedesc[I2PTransport],
  transportAddress: TransportAddress,
  settings: I2PSessionSettings,
  flags: set[ServerFlags] = {},
  upgrade: Upgrade): Self {.public.} =

  Self(
    transportAddress: transportAddress,
    upgrader: upgrade,
    tcpTransport: TcpTransport.new(flags, upgrade),
    settings: settings
  )

proc handlesDial(address: MultiAddress): bool {.gcsafe.} =
  return I2P.match(address)

proc handlesStart(address: MultiAddress): bool {.gcsafe.} =
  return mapAnd(IP, mapEq("tcp")).match(address)

proc connectToI2PServer(
    transportAddress: TransportAddress): Future[StreamTransport] {.async, gcsafe.} =
  let transp = await connect(transportAddress)
  try:
    discard await transp.write(
      sam.Message.hello
      .withMinVersion(SamMinVersion)
      .withMaxVersion(SamMaxVersion)
      .build()
    )
    let
      serverReply = sam.Answer.fromString(await transp.readLine())

    if serverReply.kind != HelloReply:
      raise newException(I2PError, fmt"Invalid handshake reply: {serverReply}")
    if serverReply.hello.kind != Ok:
      raise newException(I2PError, fmt"Unsuccessful handshake: {serverReply.hello}")

    return transp
  except CatchableError as err:
    await transp.closeWait()
    raise err

proc createControlSession(transp: StreamTransport, settings: I2PSessionSettings): Future[void] {.async, gcsafe.} =
  await transp.write(
    sam.Message.sessionCreate(Stream, settings.nickname, TRANSIENT_DESTINATION)
    .withInboundLength(settings.inboundLength)
    .withOutboundLength(settings.outboundLength)
    .withInboundQuantity(settings.inboundQuantity)
    .withOutboundQuantity(settings.outboundQuantity)
    .build()
  )
  let serverReply = sam.Answer.fromString(await transp.readLine())

  if serverReply.kind != SessionStatus:
    raise newException(I2PError, fmt"Invalid session create reply: {serverReply}")
  if serverReply.session.kind != Ok:
    raise newException(I2PError, fmt"Unsuccessful control session create: {serverReply.session}")

proc createAcceptStream(transp: StreamTransport, settings: I2PSessionSettings): Future[void] {.async, gcsafe.} =
  await transp.write(
    sam.Message.streamAccept(settings.nickname)
    .build()
  )
  let serverReply = sam.Answer.fromString(await transp.readLine())
  if serverReply.kind != StreamStatus:
    raise newException(I2PError, fmt"Invalid stream create reply: {serverReply}")
  if serverReply.stream.kind != Ok:
    raise newException(I2PError, fmt"Unsuccessful stream accept: {serverReply.session}")


proc checkControlSession(self: I2PTransport) {.async, gcsafe.} =
  if self.controlSessionConnection.isNil:
    trace "Createing control session"
    let transp = await connectToI2PServer(self.transportAddress)
    await createControlSession(transp, self.settings)
    self.controlSessionConnection = await self.tcpTransport.connHandler(transp, Opt.none(MultiAddress), Direction.Out)

proc parseI2P(address: MultiAddress): string =
  string.fromBytes(address[multiCodec("dns")].get().protoArgument().get())

proc dialPeer(
    transp: StreamTransport, address: MultiAddress, settings: I2PSessionSettings) {.async, gcsafe.} =
  let address = if I2P.match(address):
    parseI2P(address)
  else:
    raise newException(LPError, fmt"Address not supported: {address}")

  await transp.write(
    sam.Message.streamConnect(settings.nickname, address)
    .build()
  )

  let serverReply = sam.Answer.fromString(await transp.readLine())
  if serverReply.kind != StreamStatus:
    raise newException(I2PError, fmt"Invalid stream create reply: {serverReply}")
  if serverReply.stream.kind != Ok:
    raise newException(I2PError, fmt"Unsuccessful stream create to `{address}` dest: {serverReply.session}")

method dial*(
  self: I2PTransport,
  hostname: string,
  address: MultiAddress,
  peerId: Opt[PeerId] = Opt.none(PeerId)): Future[Connection] {.async, gcsafe.} =
  ## dial a peer

  if not handlesDial(address):
    raise newException(LPError, fmt"Address not supported: {address}")
  await checkControlSession(self)

  trace "Dialing remote peer", address = $address
  let transp = await connectToI2PServer(self.transportAddress)
  try:
    await dialPeer(transp, address, self.settings)
    return await self.tcpTransport.connHandler(transp, Opt.none(MultiAddress), Direction.Out)
  except CatchableError as err:
    await transp.closeWait()
    raise err

method start*(
  self: I2PTransport,
  addrs: seq[MultiAddress]) {.async.} =
  ## listen on the transport
  var listenAddrs: seq[MultiAddress]

  for i, ma in addrs:
    if not handlesStart(ma):
      warn "Invalid address detected, skipping!", address = ma
      continue
    let listenAddress = ma[0..1].get()
    listenAddrs.add(listenAddress)
  
  if listenAddrs.len != 0:
    await procCall Transport(self).start(listenAddrs)
  else:
    raise newException(TransportStartError, "Tor Transport couldn't start, no supported addr was provided.")
  
method accept*(self: I2PTransport): Future[Connection] {.async, gcsafe.} =
  await checkControlSession(self)
  let transp = await connectToI2PServer(self.transportAddress)
  await createAcceptStream(transp, self.settings)
  return await self.tcpTransport.connHandler(transp, Opt.none(MultiAddress), Direction.In)

method stop*(self: I2PTransport) {.async, gcsafe.} =
  await procCall Transport(self).stop() # call base
  await self.tcpTransport.stop()

method handles*(t: I2PTransport, address: MultiAddress): bool {.gcsafe.} =
  if procCall Transport(t).handles(address):
    return handlesDial(address) or handlesStart(address)

type
  I2PSwitch* = ref object of Switch

proc new*(
  Self: typedesc[I2PSwitch],
  i2pServer: TransportAddress,
  settings: I2PSessionSettings,
  rng: ref HmacDrbgContext,
  addresses: seq[MultiAddress] = @[],
  flags: set[ServerFlags] = {}): Self
  {.raises: [LPError, Defect], public.} =
    var builder = SwitchBuilder.new()
        .withRng(rng)
        .withTransport(proc(upgr: Upgrade): Transport = I2PTransport.new(i2pServer, settings, flags, upgr))
    if addresses.len != 0:
        builder = builder.withAddresses(addresses)
    let switch = builder.withMplex()
        .withNoise()
        .build()
    let torSwitch = Self(
      peerInfo: switch.peerInfo,
      ms: switch.ms,
      transports: switch.transports,
      connManager: switch.connManager,
      peerStore: switch.peerStore,
      dialer: Dialer.new(switch.peerInfo.peerId, switch.connManager, switch.transports, switch.ms, nil),
      nameResolver: nil)

    torSwitch.connManager.peerStore = switch.peerStore
    return torSwitch

method addTransport*(s: I2PSwitch, t: Transport) =
  doAssert(false, "not implemented!")

method getTorTransport*(s: I2PSwitch): Transport {.base.} =
  return s.transports[0]
