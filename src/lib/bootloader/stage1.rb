require "forwardable"

require "yast"
require "bootloader/udev_mapping"
require "bootloader/bootloader_factory"
require "cfa/grub2/install_device"

Yast.import "Arch"
Yast.import "BootStorage"
Yast.import "Storage"

module Bootloader
  # Represents where is bootloader stage1 installed. Allows also proposing its
  # location.
  class Stage1
    extend Forwardable
    include Yast::Logger

    attr_reader :model
    def_delegators :@model, :generic_mbr?, :generic_mbr=, :activate?, :activate=, :devices

    def initialize
      @model = CFA::Grub2::InstallDevice.new
    end

    def inspect
      "<Bootloader::Stage1 #{object_id} activate: #{activate?} " \
        "generic_mbr: #{generic_mbr?} devices: #{devices.inspect}>"
    end

    def read
      @model.load
    end

    def write
      @model.save
    end

    def include?(dev)
      kernel_dev = Bootloader::UdevMapping.to_kernel_device(dev)
      real_devs = Yast::BootStorage.underlaying_devices(kernel_dev)

      real_devs.all? do |real_dev|
        devices.any? do |map_dev|
          real_dev == Bootloader::UdevMapping.to_kernel_device(map_dev)
        end
      end
    end

    def add_udev_device(dev)
      real_devices = Yast::BootStorage.underlaying_devices(dev)
      udev_devices = real_devices.map { |d| Bootloader::UdevMapping.to_mountby_device(d) }
      udev_devices.each { |d| @model.add_device(d) }
    end

    def remove_device(dev)
      kernel_dev = Bootloader::UdevMapping.to_kernel_device(dev)

      dev = devices.find do |map_dev|
        kernel_dev == Bootloader::UdevMapping.to_kernel_device(map_dev)
      end

      @model.remove_device(dev)
    end

    def clear_devices
      devices.each do |dev|
        @model.remove_device(dev)
      end
    end

    def boot_partition?
      include?(Yast::BootStorage.BootPartitionDevice)
    end

    def root_partition?
      include?(Yast::BootStorage.RootPartitionDevice)
    end

    def mbr?
      include?(Yast::BootStorage.mbr_disk)
    end

    def extended_partition?
      return false unless Yast::BootStorage.ExtendedPartitionDevice

      include?(Yast::BootStorage.ExtendedPartitionDevice)
    end

    def custom_devices
      known_devices = [
        Yast::BootStorage.BootPartitionDevice,
        Yast::BootStorage.RootPartitionDevice,
        Yast::BootStorage.mbr_disk,
        Yast::BootStorage.ExtendedPartitionDevice
      ]
      known_devices.compact!
      known_devices.map! { |d| Bootloader::UdevMapping.to_kernel_device(d) }

      devices.select do |dev|
        !known_devices.include?(Bootloader::UdevMapping.to_kernel_device(dev))
      end
    end

    # Propose and set Stage1 location.
    # It sets properly all "boot_*" entries in globals. It also sets if partition
    # should be activated by setting its boot flag (in globals key "activate").
    # It proposes if generic_mbr will be written into MBR (globals key "generic_mbr").
    # And last but not least it propose if protective MBR flag need to be removed
    # The proposal is only based on storage information, disregarding any
    # existing values of the output variables (which are respected at other times, in AutoYaST).
    # @see for keys in globals to https://old-en.opensuse.org/YaST/Bootloader_API#global_options_in_map
    def propose
      case Yast::Arch.architecture
      when "i386", "x86_64"
        propose_x86
      when /ppc/
        propose_ppc
      when /s390/
        propose_s390
      else
        raise "unsuported architecture #{Yast::Arch.architecture}"
      end

      log.info "proposed stage1 configuratopn #{inspect}"
    end

    # returns hash, where key is symbol for location and value is device name
    def available_locations
      res = {}

      case Yast::Arch.architecture
      when "i386", "x86_64"
        available_partitions(res)
        res[:mbr] = Yast::BootStorage.mbr_disk
      else
        log.info "no available non-custom location for arch #{Yast::Arch.architecture}"
      end

      res
    end

    def can_use_boot?
      tm = Yast::Storage.GetTargetMap
      partition = Yast::BootStorage.BootPartitionDevice

      part = Yast::Storage.GetPartition(tm, partition)

      if !part
        log.error "cannot find partition #{partition}"
        return false
      end

      log.info "Boot partition info #{part.inspect}"

      # cannot install stage one to xfs as it doesn't have reserved space (bnc#884255)
      return false if part["used_fs"] == :xfs

      true
    end

  private

    def available_partitions(res)
      return unless can_use_boot?

      if separated_boot?
        res[:boot] = Yast::BootStorage.BootPartitionDevice
      else
        res[:root] = Yast::BootStorage.RootPartitionDevice
      end
      res[:extended] = extended if logical_boot?
    end

    def propose_x86
      selected_location = propose_boot_location
      log.info "propose_x86 (#{selected_location})"

      # set active flag, if needed
      if selected_location == :mbr
        # We are installing into MBR:
        # If there is an active partition, then we do not need to activate
        # one (otherwise we do).
        # Reason: if we use our own MBR code, we do not rely on the activate
        # flag in the partition table to boot Linux. Thus, the activated
        # partition can remain activated, which causes less problems with
        # other installed OSes like Windows (older versions assign the C:
        # drive letter to the activated partition).
        used_disks = Yast::BootStorage.underlaying_devices(Yast::BootStorage.mbr_disk)
        need_activate = used_disks.any? { |d| Yast::Storage.GetBootPartition(d).empty? }
        self.activate = need_activate
        self.generic_mbr = false
      else
        # if not installing to MBR, always activate (so the generic MBR will
        # boot Linux)
        self.activate = true
        self.generic_mbr = true
      end
    end

    def propose_s390
      # s390 do not need any partition as it is stored to predefined zipl location
      assign_bootloader_device(:none)

      self.activate = false
      self.generic_mbr = false
    end

    def propose_ppc
      partition = proposed_prep_partition
      if partition
        assign_bootloader_device([:custom, partition])

        self.activate = true
        self.generic_mbr = false
      # handle diskless setup, in such case do not write boot code anywhere (bnc#874466)
      # we need to detect what is mount on /boot and if it is nfs, then just
      # skip this proposal. In other case if it is not nfs, then it is error and raise exception
      # powernv do not have prep partition, so we do not have any partition to activate (bnc#970582)
      elsif Yast::BootStorage.disk_with_boot_partition == "/dev/nfs" || Yast::Arch.board_powernv
        self.activate = false
        self.generic_mbr = false
        return
      else
        raise "there is no prep partition"
      end
    end

    def proposed_prep_partition
      partitions = Yast::BootStorage.prep_partitions

      created = partitions.find do |part|
        part_map = Yast::Storage.GetPartition(Yast::Storage.GetTargetMap, part)
        part_map["create"] == true
      end

      if created
        log.info "using freshly created prep partition #{created}"
        return created
      end

      same_disk_part = partitions.find do |part|
        disk = Yast::Storage.GetDiskPartition(part)["disk"]
        Yast::BootStorage.disk_with_boot_partition == disk
      end

      if same_disk_part
        log.info "using prep on boot disk #{same_disk_part}"
        return same_disk_part
      end

      log.info "nothing better so lets return first available prep"
      partitions.first
    end

    def separated_boot?
      Yast::BootStorage.BootPartitionDevice != Yast::BootStorage.RootPartitionDevice
    end

    def propose_boot_location
      selected_location = :mbr

      # there was check if boot device is on logical partition
      # IMO it is good idea check MBR also in this case
      # see bug #279837 comment #53
      selected_location = separated_boot? ? :boot : :root if boot_partition_on_mbr_disk?

      if logical_boot? && extended_partition
        log.info "/boot is on logical partition and extended detected, extended proposed"
        selected_location = :extended
      end

      # for separate btrfs partition prefer MBR (bnc#940797)
      if boot_with_btrfs? && (logical_boot? || separated_boot?)
        log.info "/boot is on logical partition or separated and uses btrfs, mbr is preferred"
        selected_location = :mbr
      end

      if !can_use_boot?
        log.info "/boot cannot be used to install stage1"
        selected_location = :mbr
      end

      assign_bootloader_device(selected_location)
    end

    def extended_partition
      init_boot_info unless @boot_initialized

      @extended
    end

    def logical_boot?
      init_boot_info unless @boot_initialized

      @logical_boot
    end

    def boot_with_btrfs?
      init_boot_info unless @boot_initialized

      @boot_with_btrfs
    end

    def init_boot_info
      return if @boot_initialized

      @boot_initialized = true
      boot_disk_map = Yast::Storage.GetTargetMap[Yast::BootStorage.disk_with_boot_partition] || {}
      boot_part = Yast::Storage.GetPartition(Yast::Storage.GetTargetMap,
        Yast::BootStorage.BootPartitionDevice)
      @logical_boot = boot_part["type"] == :logical
      @boot_with_btrfs = boot_part["used_fs"] == :btrfs

      # check for sure also underlaying partitions
      (boot_disk_map["partitions"] || []).each do |p|
        @extended = p["device"] if p["type"] == :extended
        next unless underlaying_boot_partition_devices.include?(p["device"])

        @boot_with_btrfs = true if p["used_fs"] == :btrfs
        @logical_boot = true if p["type"] == :logical
      end
    end

    # Set "boot_*" flags in the globals map according to the boot device selected
    # with parameter selected_location. Only a single boot device can be selected
    # with this function. The function cannot be used to set a custom boot device.
    # It will always be deleted.
    #
    # FIXME: `mbr_md is probably unneeded; AFA we can see, this decision is
    # automatic anyway and perl-Bootloader should be able to make it without help
    # from the user or the proposal.
    #
    # @param [Symbol, Array] selected_location symbol one of :boot, :root, :mbr,
    #   :extended, `none or Array with first value :custom and second device for
    #   custom devices
    def assign_bootloader_device(selected_location)
      log.info "assign bootloader device '#{selected_location.inspect}'"
      # first, default to all off:
      clear_devices

      case selected_location
      when :root then add_udev_device(Yast::BootStorage.RootPartitionDevice)
      when :boot then add_udev_device(Yast::BootStorage.BootPartitionDevice)
      when :extended then add_udev_device(extended)
      when :mbr then add_udev_device(Yast::BootStorage.mbr_disk)
      when :none then log.info "Resetting bootloader device"
      when Array
        if selected_location.first != :custom
          raise "Unknown value to select bootloader device #{selected_location.inspect}"
        end

        @model.add_device(selected_location[1]) # add directly proposed value without changes
      else
        raise "Unknown value to select bootloader device #{selected_location.inspect}"
      end
    end

    # determine the underlaying devices for the "/boot" partition (either the
    # BootPartitionDevice, or the devices from which the soft-RAID device for
    # "/boot" is built)
    def underlaying_boot_partition_devices
      Yast::BootStorage.underlaying_devices(Yast::BootStorage.BootPartitionDevice)
    end

    def boot_partition_on_mbr_disk?
      underlaying_boot_partition_devices.any? do |dev|
        pdp = Yast::Storage.GetDiskPartition(dev)
        p_disk = pdp["disk"] || ""
        p_disk == Yast::BootStorage.mbr_disk
      end
    end
  end
end
