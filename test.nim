import libp2p
import stew/byteutils

let kek = MultiAddress.init("/dns/kek.lol/http").tryGet()
echo kek[multiCodec("dns")].get()[1].get()
