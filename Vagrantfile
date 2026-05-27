# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Local CI mirror: spin up disposable Ubuntu 22.04 and 24.04 VMs under
# libvirt, rsync the working tree in, and run the same converge +
# integration test sequence GitHub Actions runs on the hosted runners.
#
# Usage from the repo root:
#   vagrant up                       # both platforms, in parallel
#   vagrant up ubuntu-22.04          # one platform only
#   vagrant provision ubuntu-24.04   # re-run the test pass on an existing VM
#   vagrant destroy -f               # tear everything down
#
# One-time host setup on Fedora:
#   sudo dnf install -y vagrant vagrant-libvirt libvirt
#   sudo systemctl enable --now libvirtd
#
# The branch persisted into the in-VM converge defaults to whatever the
# local checkout is on, so the tests run against the code you have staged
# locally rather than what is currently on origin/testing.

ENV["VAGRANT_DEFAULT_PROVIDER"] ||= "libvirt"
# vagrant-libvirt otherwise defaults to qemu:///session (per-user) which
# fails to connect on Fedora. Use the system libvirtd that the libvirt
# group authorizes.
ENV["LIBVIRT_DEFAULT_URI"] ||= "qemu:///system"

TEST_GIT_BRANCH = ENV["TEST_GIT_BRANCH"] || `git rev-parse --abbrev-ref HEAD`.strip

# `bento/ubuntu-22.04` does not boot reliably under vagrant-libvirt 0.11
# (no DHCP-lease scrape, and the qemu-agent path stalls before SSH comes
# up). Use the `generic/` box for 22.04 specifically; bento works fine
# for 24.04 so we leave that alone.
GUESTS = {
  "ubuntu-22.04" => "generic/ubuntu2204",
  "ubuntu-24.04" => "bento/ubuntu-24.04",
}.freeze

Vagrant.configure("2") do |config|
  GUESTS.each do |name, box|
    config.vm.define name do |vm|
      vm.vm.box = box
      vm.vm.hostname = name.tr(".", "-")

      vm.vm.synced_folder ".", "/vagrant",
        type: "rsync",
        rsync__exclude: %w[
          .git/
          .venv/
          .pre-commit-cache/
          .ansible/
          .vagrant/
          __pycache__/
        ]

      # Generous boot window so a slow first-boot does not trip vagrant's
      # SSH wait. Cheap on success — only matters when the VM is sluggish.
      vm.vm.boot_timeout = 600

      vm.vm.provider "libvirt" do |lv|
        lv.memory = 2048
        lv.cpus = 2
      end

      vm.vm.provision "shell",
        path: "scripts/local-ci-provision.sh",
        env: { "TEST_GIT_BRANCH" => TEST_GIT_BRANCH }
    end
  end
end
