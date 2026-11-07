# frozen_string_literal: true

# disktriage's Homebrew formula. The tap is the v1 distribution route; a
# signed .app is P4 and needs a Developer ID, which is out of scope here.
#
# Licence: the repository has no LICENSE file yet. `:cannot_represent` is a
# deliberate placeholder, not a guess; the human must choose a licence before
# the tap is published. See docs/packaging.md and
# docs/adr/0022-homebrew-packaging.md.
#
# GPL: ntfs-3g's userspace tools are a separate GPL subprocess, built from the
# upstream tarball by the user's machine. They are not bundled into and not
# linked with the disktriage binary.
#
# The source url and sha256 below are placeholders that
# `scripts/package.sh formula` replaces with the local tarball for
# verification; a release substitutes the published archive.
class Disktriage < Formula
  desc "Triage a failing disk from hardware signals, image it, and hand off"
  homepage "https://github.com/autox-my/disktriage"
  url "__DISKTRIAGE_SOURCE_URL__"
  sha256 "__DISKTRIAGE_SOURCE_SHA256__"
  license :cannot_represent

  depends_on xcode: ["16.0", :build]
  depends_on "ddrescue"
  depends_on macos: :ventura
  depends_on "smartmontools"

  resource "ntfs-3g" do
    url "https://download.tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.9.28.tgz"
    sha256 "350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8"
  end

  def install
    # ntfsprogs only. --disable-ntfs-3g is the exact flag that turns the FUSE
    # driver off: configure never looks for libfuse, and no mount helper is
    # installed (docs/ntfs-spike.md, "How to build"). Static tools keep the
    # keg relocatable; --exec-prefix must match --prefix or install writes to
    # /lib. Homebrew's gettext header must not be picked up: the package then
    # calls libintl_setlocale without linking -lintl, so the cache variable
    # keeps NLS off and adds no gettext dependency.
    resource("ntfs-3g").stage do
      system "./configure",
             "ac_cv_header_libintl_h=no",
             "--prefix=#{libexec}/ntfs-3g",
             "--exec-prefix=#{libexec}/ntfs-3g",
             "--disable-ntfs-3g",
             "--disable-shared",
             "--enable-static",
             "--disable-ldconfig",
             "--disable-mtab",
             "--disable-mount-helper"
      system "make", "-j#{ENV.make_jobs}"
      system "make", "install"
    end

    system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "disktriage"
    bin.install ".build/release/disktriage"
  end

  test do
    assert_match "disktriage #{version}", shell_output("#{bin}/disktriage --version")

    # check is read-only and needs neither root nor Full Disk Access. Other
    # rows may be UNVERIFIABLE on a headless host, so 0/1/3 are all valid
    # verdicts; the ntfs-3g row itself must be PASS from the keg's libexec.
    require "json"
    require "open3"
    json, status = Open3.capture2((bin/"disktriage").to_s, "check", "--json")
    assert_includes [0, 1, 3], status.exitstatus, "check exits 0, 1 or 3"
    report = JSON.parse(json)
    ntfs = report.fetch("checks").find { |row| row["id"] == "ntfs-3g" }
    assert ntfs, "the ntfs-3g row is present"
    assert_equal "PASS", ntfs["status"], "ntfs-3g is found in the keg's libexec"

    # No FUSE linkage anywhere: configure was run with --disable-ntfs-3g and
    # the tools are statically linked. otool is the evidence.
    %w[ntfsinfo ntfsls ntfscat ntfscluster].each do |tool|
      linkage = shell_output("xcrun otool -L #{libexec}/ntfs-3g/bin/#{tool}")
      refute_match(/fuse/i, linkage)
    end
    refute_match(/fuse/i, shell_output("xcrun otool -L #{bin}/disktriage"))
  end
end
