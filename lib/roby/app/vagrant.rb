# frozen_string_literal: true

module Roby
    module App
        # Utilities related to Vagrant VMs
        module Vagrant
            # Exception thrown when trying to resolve a vagrant VM and it is not
            # running
            class NotRunning < ArgumentError; end

            # Exception raise when trying to resolve a vagrant VM but cannot find it
            class NotFound < ArgumentError; end

            # Exception raised when a vagrant VM could be found, but its IP cannot
            # be resolved through 'vagrant ssh-config'
            class CannotResolveHostname < ArgumentError; end

            # Resolves the global ID of a vagrant VM
            #
            # @param [String] vagrant_name the name or ID of the vagrant VM
            # @raise VagrantVMNotFound
            # @raise VagrantVMNotRunning
            def self.resolve_vm(vagrant_name)
                IO.popen(%w[vagrant global-status]).each_line do |line|
                    id, name, _, state, * = line.chomp.split(/\s+/)
                    if vagrant_name == id || vagrant_name == name
                        if state != "running"
                            raise NotRunning,
                                  "cannot connect to vagrant VM #{vagrant_name}: " \
                                  "in state #{state} (requires running)"
                        end

                        return id
                    end
                end
                raise NotFound,
                      "cannot find a vagrant VM called #{vagrant_name}, " \
                      "run vagrant global-status to check vagrant's status"
            end

            # Resolve the IP of a vagrant VM
            def self.resolve_ip(vagrant_name)
                id = resolve_vm(vagrant_name)
                IO.popen(["vagrant", "ssh-config", id]).each_line do |line|
                    if line =~ /HostName (.*)/
                        return $1.strip
                    end
                end
                raise CannotResolveHostname,
                      "did not find a Hostname in the ssh-config of vagrant VM " \
                      "#{vagrant_name} (with id #{id}). Check the result of " \
                      "vagrant ssh-config #{id}"
            end
        end
    end
end
