# The package is built from artefacts, not from source: the Flutter bundle and
# the Go binary are produced by the release workflow (or by
# packaging/build-rpm.sh locally) and arrive here as one tarball. Building
# Flutter inside rpmbuild would mean pulling the SDK and the pub cache from
# the network during %build, which no distribution build system allows.
Name:           lumeo
Version:        %{?version}%{!?version:0.1.0}
Release:        1%{?dist}
Summary:        Find, acquire and watch films and series

License:        MIT
URL:            https://github.com/eeegoloauq/lumeo
Source0:        %{name}-%{version}-linux-x86_64.tar.gz
ExclusiveArch:  x86_64

BuildRequires:  desktop-file-utils
BuildRequires:  libappstream-glib

# libmpv is opened with dlopen() from Dart, so it leaves no DT_NEEDED entry
# and rpm's automatic dependency generator cannot see it. Without this line
# the package installs and the player fails at the first frame.
Requires:       mpv-libs
Requires:       gtk3
# Fedora builds libavcodec without the patented decoders, so mpv-libs alone is
# not enough to play most of what a swarm actually carries. Two different
# failures, and the second is the worse one:
#
#   - HEVC and E-AC-3 are simply absent, and the copy opens black or silent.
#   - h264 is absent too, but Fedora fills the hole with Cisco's libopenh264,
#     which plays and does not survive a backward seek: the sound lands seconds
#     away from the picture. mpv closes those reports as a broken decoder
#     rather than a bug (mpv-player/mpv#15837), and it looks for all the world
#     like a bug in whoever asked for the seek.
#
# This is a Recommends rather than a Requires on purpose: the package lives in
# RPM Fusion, dnf pulls it in for anyone who has that enabled and installs us
# anyway for anyone who does not. The player says which decoder is missing, or
# which one is going to lose the sound, and how to get it.
Recommends:     libavcodec-freeworld

%description
Lumeo is a media library, acquisition and playback platform: one Go binary
with SQLite behind a Flutter desktop client. It browses a catalogue that needs
no API key, ranks the ways to watch a title by the health of the swarm before
its resolution, and plays the file while it is still arriving.

%global debug_package %{nil}
# Old rpm builds (and non-Fedora ones) do not define where AppStream metadata
# goes; the path itself has been the same everywhere for years.
%{!?_metainfodir: %global _metainfodir %{_datadir}/metainfo}

%prep
%setup -q -n %{name}-%{version}-linux-x86_64

%build
# Nothing to build: see the note at the top.

%install
# The bundle stays in one piece. The Flutter binary looks for its engine and
# plugin libraries at $ORIGIN/lib, and for the core it starts beside itself,
# so splitting them apart breaks the app.
install -d %{buildroot}%{_libdir}/%{name}
cp -a bundle/. %{buildroot}%{_libdir}/%{name}/
install -Dm755 lumeo.sh %{buildroot}%{_bindir}/%{name}

install -Dm644 dev.lumeo.lumeo.desktop \
  %{buildroot}%{_datadir}/applications/dev.lumeo.lumeo.desktop
install -Dm644 dev.lumeo.lumeo.metainfo.xml \
  %{buildroot}%{_metainfodir}/dev.lumeo.lumeo.metainfo.xml
# The icon sizes are rendered in build-dist.sh, once for every package.
install -d %{buildroot}%{_datadir}/icons
cp -a icons/hicolor %{buildroot}%{_datadir}/icons/

%check
# gdk-pixbuf (GNOME Shell's app grid) sniffs only the first bytes for "<svg";
# rsvg-convert in build-dist.sh does not, so a long preamble passes the build
# unnoticed.
head -c 200 %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/dev.lumeo.lumeo.svg | grep -q '<svg'
desktop-file-validate %{buildroot}%{_datadir}/applications/dev.lumeo.lumeo.desktop
appstream-util validate-relax --nonet \
  %{buildroot}%{_metainfodir}/dev.lumeo.lumeo.metainfo.xml

%files
%license LICENSE
%{_bindir}/%{name}
%{_libdir}/%{name}/
%{_datadir}/applications/dev.lumeo.lumeo.desktop
%{_metainfodir}/dev.lumeo.lumeo.metainfo.xml
%{_datadir}/icons/hicolor/*/apps/dev.lumeo.lumeo.*

# Filled by build-rpm.sh from the AppStream releases (release-notes.py).
%changelog
