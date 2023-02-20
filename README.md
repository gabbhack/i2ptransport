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

## Start
To run [examples](https://github.com/gabbhack/i2ptransport/tree/master/examples) you must download some I2P Client (i.e. [i2pd](https://i2pd.website/)) and enable SAM Protocol in settings.

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