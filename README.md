# SeedLink Viewer

This is a simple utility for visualizing seismic waveforms via the SeedLink protocol - typically that
means inspecting the contents of a RingServer.  If you want a more feature rich viewer then use 
[Swarm](https://gitlab.com/seismic-software/swarm/-/releases).

# Getting Started

Your best bet is to check the artifacts from the latest build for the appropriate 
binary (see the [Actions](https://github.com/uofuseismo/seedlink_viewer/actions) tab).

Still reading?  Bummer.  Well, the next step is to mimic the .github/workflows on your computer.

## Current libmseed and libslink versions are 

    git subtree add --prefix third_party/libmseed https://github.com/EarthScope/libmseed fa0fa6d927a26141eb2d1ea08d9ca6afc00485f7 --squash
    git subtree add --prefix third_party/libslink https://github.com/EarthScope/libslink e886e3bae1014ca70ff347d51de9a6441628c37c --squash 
