# Package

version       = "0.1.0"
author        = "Gabben"
description   = "I2P Transport for libp2p"
license       = "MIT"
srcDir        = "src"
skipDirs      = @["tests", "examples"]

# Dependencies

requires "nim >= 1.2.0",
         "libp2p",
         "https://github.com/gabbhack/sam_protocol"
