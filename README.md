# i2ptransport [![nim-version-img]][nim-version]

[nim-version]: https://nim-lang.org/blog/2020/04/03/version-120-released.html
[nim-version-img]: https://img.shields.io/badge/Nim_-v1.2.0%2B-blue

**I2P Transport for** [nim-libp2p](https://github.com/status-im/nim-libp2p)

```bash
nimble install https://github.com/gabbhack/i2ptransport
```

[Examples](https://github.com/gabbhack/i2ptransport/tree/master/examples)

---
This library implements [I2P](https://geti2p.net/) [Transport](https://docs.libp2p.io/concepts/transports/overview/) for [nim-libp2p](https://github.com/status-im/nim-libp2p) via [SAM Protocol](https://geti2p.net/en/docs/api/samv3).

## Quickstart
1. Make sure your i2p router has sam proxy enabled.

2. You must have or generate a destination and a private key.

<details> 
<summary>Keys?</summary>

Check documentation for `DEST GENERATE` command in [SAMv3 spec](https://geti2p.net/en/docs/api/samv3).

</details>

If you already have keys, pass them to the I2PKeyPair constructor:
```nim
let keys = I2PKeyPair.init(
  destination="...",
  privateKey="..."
)
```

Or generate them
```nim
let keys = await generateDestination()
```

3. Init session settings

Every session in I2P is associated with some ID (or nickname).
```nim
let settings = I2PSessionSettings.init(
  nickname = "nickname"
)
```

4. Init transport

```nim
let transport = I2PTransport.init(
  settings,
  keys
)
```

5. Or use `I2PSwitch`

```nim
let switch = I2PSwitch.new(
  settings,
  keys,
  newRng()
)
```

If you don't know what to do about it, check out the [examples](https://github.com/gabbhack/i2ptransport/tree/master/examples).

## Address
At the moment nim-libp2p does not have the [garlic](https://github.com/multiformats/multicodec/blob/master/table.csv#L120) protocol, so dns is exploited.

`I2PTransport` generate and accepts something like `/dns/randomstring/...`.

## FAQ
- Is it safe? IDK

## License
Licensed under <a href="LICENSE">MIT license</a>.

## Acknowledgements
- [nim-libp2p](https://github.com/status-im/nim-libp2p), for Nim libp2p
- [i2pd](https://github.com/PurpleI2P/i2pd), for I2P client