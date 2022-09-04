`cloudi_api_haskell`
====================

[![Hackage version](https://img.shields.io/hackage/v/cloudi.svg?label=Hackage)](https://hackage.haskell.org/package/cloudi)

Haskell [CloudI API](https://cloudi.org/api.html#1_Intro)

Build
-----

With cabal-install >= 3.4

    cabal v2-update
    mkdir sandbox
    cabal --store-dir=./sandbox v2-configure
    cabal v2-build

With cabal-install >= 2.4 and cabal-install < 3.4

    cabal v1-sandbox init
    cabal v1-update
    cabal v1-install --only-dependencies
    cabal v1-configure
    cabal v1-build

With cabal-install < 2.4

    cabal sandbox init
    cabal update
    cabal install --only-dependencies
    cabal configure
    cabal build

Without cabal-install

    mkdir -p dist/setup-bin
    ghc --make -outputdir dist/setup-bin -o dist/setup-bin/Setup ./Setup.hs
    dist/setup-bin/Setup configure --builddir=./dist --enable-deterministic --disable-shared --enable-static
    dist/setup-bin/Setup build

Author
------

Michael Truog (mjtruog at protonmail dot com)

License
-------

MIT License

