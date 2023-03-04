# Package

version       = "0.1.4"
author        = "Gabben"
description   = "I2P Transport for libp2p"
license       = "MIT"
srcDir        = "src"
skipDirs      = @["tests", "examples"]

# Dependencies

requires "nim >= 1.6.0",
         "libp2p",
         "samprotocol >= 0.1.1"
