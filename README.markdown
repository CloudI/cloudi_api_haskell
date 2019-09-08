`cloudi_api_haskell`
====================

[![Hackage version](https://img.shields.io/hackage/v/cloudi.svg?label=Hackage)](https://hackage.haskell.org/package/cloudi)

Haskell [CloudI API](https://cloudi.org/api.html#1_Intro)

Build
-----

With cabal-install < 2.4

    cabal sandbox init
    cabal update
    cabal install --only-dependencies
    cabal configure
    cabal build

With cabal-install >= 2.4

    cabal v1-sandbox init
    cabal v1-update
    cabal v1-install --only-dependencies
    cabal v1-configure
    cabal v1-build

Author
------

Michael Truog (mjtruog at protonmail dot com)

License
-------

MIT License

