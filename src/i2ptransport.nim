when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[strformat, options]
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
  I2PSessionSettings* = object
    inboundLength: int  ## Length of tunnels in
    outboundLength: int  ## Length of tunnels out
    inboundQuantity: int  ## Number of tunnels in
    outboundQuantity: int  ## Number of tunnels out
    nickname: string  ## Session ID
    signatureType: sam.SignatureType
  
  I2PKeyPair* = object
    destination: string
    privateKey: string

  I2PTransport* = ref object of Transport
    samAddress: TransportAddress  ## SAM proxy address
    tcpTransport: TcpTransport  ## Underlying transport
    controlConnection: Connection  ## Connection of control session
    sessionSettings: I2PSessionSettings
    keyPair: I2PKeyPair

  TransportStartError* = object of transport.TransportError
  I2PError* = object of CatchableError


logScope:
  topics = "i2p transport"


const
  I2P* = DNS
  TCPIP = mapAnd(IP, mapEq("tcp"))
  SamMinVersion* = "3.1"
  SamMaxVersion* = "3.1"


proc handlesDial(address: MultiAddress): bool {.gcsafe.}
proc handlesStart(address: MultiAddress): bool {.gcsafe.}
proc samHandshake(transport: StreamTransport) {.async, gcsafe.}
proc connectToSam(samAddress: TransportAddress): Future[StreamTransport] {.async, gcsafe.}
proc readAnswer(transport: StreamTransport): Future[sam.Answer] {.async, gcsafe.}
proc createControlConnection(self: I2PTransport) {.async, gcsafe.}
proc parseI2P(address: MultiAddress): string {.gcsafe.}
proc connectStream(transport: StreamTransport, address: MultiAddress, settings: I2PSessionSettings) {.async, gcsafe.}
proc acceptStream(transport: StreamTransport, settings: I2PSessionSettings) {.async, gcsafe.}


proc init*(
  Self: typedesc[I2PSessionSettings],
  nickname: string,
  inboundLength = 3,
  outboundLength = 3,
  inboundQuantity = 5,
  outboundQuantity = 5,
  signatureType = EdDSA_SHA512_Ed25519
): Self {.public.} =
  Self(
    nickname: nickname,
    inboundLength: inboundLength,
    outboundLength: outboundLength,
    inboundQuantity: inboundQuantity,
    outboundQuantity: outboundQuantity,
    signatureType: signatureType
  )

proc init*(
  Self: typedesc[I2PKeyPair],
  destination: string,
  privateKey: string
): Self {.public.} =
  Self(
    destination: destination,
    privateKey: privateKey
  )

proc new*(
  Self: typedesc[I2PTransport],
  sessionSettings: I2PSessionSettings,
  keyPair: I2PKeyPair,
  samAddress = initTAddress("127.0.0.1:7656"),
  flags: set[ServerFlags] = {},
  upgrade: Upgrade
): Self {.public.} =
  Self(
    samAddress: samAddress,
    upgrader: upgrade,
    tcpTransport: TcpTransport.new(flags, upgrade),
    sessionSettings: sessionSettings,
    keyPair: keyPair
  )

method start*(
  self: I2PTransport,
  addrs: seq[MultiAddress]) {.async.} =
  ## listen on the transport
  if self.running:
    warn "I2P transport already running"
    return

  let destination = self.keyPair.destination
  await createControlConnection(self)
  await procCall Transport(self).start(@[MultiAddress.init(fmt"/dns/{destination}").tryGet()])

method dial*(
  self: I2PTransport,
  hostname: string,
  address: MultiAddress,
  peerId: Opt[PeerId] = Opt.none(PeerId)): Future[Connection] {.async, gcsafe.} =
  ## dial a peer
  if not self.running:
    raise newTransportClosedError()

  if not handlesDial(address):
    raise newException(LPError, fmt"Address not supported: {address}")

  trace "Dialing remote peer", address = $address
  let transport = await connectToSam(self.samAddress)
  try:
    await connectStream(transport, address, self.sessionSettings)
    return await self.tcpTransport.connHandler(transport, Opt.none(MultiAddress), Direction.Out)
  except CatchableError as err:
    await transport.closeWait()
    raise err

method accept*(self: I2PTransport): Future[Connection] {.async, gcsafe.} =
  if not self.running:
    raise newTransportClosedError()
  let transport = await connectToSam(self.samAddress)
  try:
    await acceptStream(transport, self.sessionSettings)

    let fromDestination = await transport.readLine(sep="\n")
    debug "New accept", destination = fromDestination

    return await self.tcpTransport.connHandler(transport, Opt.none(MultiAddress), Direction.In)
  except CatchableError as err:
    await transport.closeWait()
    raise err

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
  settings: I2PSessionSettings,
  keyPair: I2PKeyPair,
  rng: ref HmacDrbgContext,
  samAddress = initTAddress("127.0.0.1:7656"),
  addresses: seq[MultiAddress] = @[],
  flags: set[ServerFlags] = {}): Self
  {.raises: [LPError, Defect], public.} =
    var builder = SwitchBuilder.new()
        .withRng(rng)
        .withTransport(proc(upgr: Upgrade): Transport = I2PTransport.new(settings, keyPair, samAddress, flags, upgr))
    if addresses.len != 0:
        builder = builder.withAddresses(addresses)
    let switch = builder.withMplex()
        .withNoise()
        .build()
    let i2pSwitch = Self(
      peerInfo: switch.peerInfo,
      ms: switch.ms,
      transports: switch.transports,
      connManager: switch.connManager,
      peerStore: switch.peerStore,
      dialer: Dialer.new(switch.peerInfo.peerId, switch.connManager, switch.transports, switch.ms, nil),
      nameResolver: nil)

    i2pSwitch.connManager.peerStore = switch.peerStore
    return i2pSwitch

method addTransport*(s: I2PSwitch, t: Transport) =
  doAssert(false, "not implemented!")

method getI2PTransport*(s: I2PSwitch): Transport {.base.} =
  return s.transports[0]

proc createControlConnection(self: I2PTransport) {.async, gcsafe.} =
  let
    settings = self.sessionSettings
    transport = await connectToSam(self.samAddress)
    message = sam.Message.sessionCreate(Stream, settings.nickname, self.keyPair.privateKey)
      .withInboundLength(settings.inboundLength)
      .withOutboundLength(settings.outboundLength)
      .withInboundQuantity(settings.inboundQuantity)
      .withOutboundQuantity(settings.outboundQuantity)
      .build()

  debug "Creating control session", nickname = settings.nickname
  discard await transport.write(message)

  let answer = await transport.readAnswer()
  if answer.session.kind != Ok:
    await transport.closeWait()
    raise newException(I2PError, fmt"Unsuccessful control session create for nickname `{settings.nickname}`: {answer.session}")

  let connection = await self.tcpTransport.connHandler(transport, Opt.none(MultiAddress), Direction.Out)
  # The control connection must not disconnect by timeout
  connection.timeout = InfiniteDuration

proc generateDestination*(
  samAddress = initTAddress("127.0.0.1:7656"),
  signatureType = EdDSA_SHA512_Ed25519
): Future[I2PKeyPair] {.async, gcsafe.} =
  let
    transport = await connectToSam(samAddress)
    message = sam.Message.destGenerate()
      .withSignatureType(signatureType)
      .build()

  debug "Generate destination", message = message
  try:
    discard await transport.write(message)

    let answer = await transport.readAnswer()
    return I2PKeyPair.init(
      destination=answer.dest.pub,
      privateKey=answer.dest.priv
    )
  except CatchableError as err:
    await transport.closeWait()
    raise err

proc connectToSam(samAddress: TransportAddress): Future[StreamTransport] {.async, gcsafe.} =
  debug "Connecting to SAM", address = samAddress

  let transport = await connect(samAddress)
  try:
    await samHandshake(transport)
  except CatchableError as err:
    await transport.closeWait()
    raise err
  return transport

proc connectStream(transport: StreamTransport, address: MultiAddress, settings: I2PSessionSettings) {.async, gcsafe.} =
  let address =
    if I2P.match(address):
      parseI2P(address)
    else:
      raise newException(LPError, fmt"Address not supported: {address}")

  let message = sam.Message.streamConnect(settings.nickname, address)
    .build()

  debug "Connect stream", message = message
  discard await transport.write(message)

  let answer = await transport.readAnswer()
  if answer.stream.kind != Ok:
    raise newException(I2PError, fmt"Unsuccessful stream create to `{address}` destination: {answer.stream}")

proc acceptStream(transport: StreamTransport, settings: I2PSessionSettings) {.async, gcsafe.} =
  let message = sam.Message.streamAccept(settings.nickname)
    .build()

  debug "Accept stream", message = message
  discard await transport.write(message)

  let answer = await transport.readAnswer()
  if answer.stream.kind != Ok:
    raise newException(I2PError, fmt"Unsuccessful stream accept: {answer.stream}")

proc samHandshake(transport: StreamTransport) {.async, gcsafe.} =
  let message = sam.Message.hello
    .withMinVersion(SamMinVersion)
    .withMaxVersion(SamMaxVersion)
    .build()

  debug "Sending handshake", message = message
  discard await transport.write(message)

  let answer = await transport.readAnswer()

  if answer.hello.kind != Ok:
    raise newException(I2PError, fmt"Unsuccessful handshake: {answer.hello}")

proc readAnswer(transport: StreamTransport): Future[sam.Answer] {.async, gcsafe.} =
  return sam.Answer.fromString(await transport.readLine(sep="\n"))

proc handlesDial(address: MultiAddress): bool {.gcsafe.} =
  return I2P.match(address)

proc handlesStart(address: MultiAddress): bool {.gcsafe.} =
  return TCPIP.match(address)

proc parseI2P(address: MultiAddress): string {.gcsafe.} =
  string.fromBytes(address[multiCodec("dns")].get().protoArgument().get())
