# frozen_string_literal: true

module Roby
    module App
        # Reporter class for the Roby autotest, that outputs on an IO object
        class AutotestConsoleReporter
            # @return [#puts] the IO on which reporting should be done
            attr_reader :io

            # @return [App::TestServer] the test server
            attr_reader :server

            # @return [Autorespawn::Manager] the autorespawn slave manager
            attr_reader :manager

            # @return [Hash<Autorespawn::Slave,Integer>] mapping from
            #   a slave to the unique ID associated with it
            attr_reader :slave_to_id

            # @return [Hash<Integer,Autorespawn::Slave>] mapping from
            #   a process ID to the slave object
            attr_reader :pid_to_slave

            # @api private
            #
            # Converts a slave object to the string displayed to the user
            def slave_to_s(slave)
                slave.name.sort_by(&:first).map { |k, v| "#{k}: #{v}" }
            end

            # @api private
            #
            # Register a new slave
            #
            # @return [Integer] the unique slave ID
            def register_slave(slave)
                if slave_to_id[slave]
                    raise ArgumentError, "#{slave} is already registered"
                end

                slave_to_id[slave] = (@slave_id += 1)
            end

            # @api private
            #
            # Register a new slave-to-PID mapping
            #
            # @param [Autorespawn::Slave] slave a slave whose #pid is valid
            # @return [Integer] the slave's unique slave ID
            # @raise [ArgumentError] if the slave has not been registered with
            #   {#register_slave} first
            def register_slave_pid(slave)
                if (slave_id = slave_to_id[slave])
                    pid_to_slave[slave.pid] = slave
                    slave_id
                else
                    raise ArgumentError, "#{slave} has not been registered with #register_slave"
                end
            end

            # @api private
            #
            # Returns a slave from its PID
            #
            # @param [Integer] pid the PID
            # @return [(Autorespawn::Slave,Integer)] the slave and its unique
            #   slave ID
            # @raise [ArgumentError] if no slave is registered for this PID
            def slave_from_pid(pid)
                if (slave = pid_to_slave[pid])
                    [slave, slave_to_id[slave]]
                else
                    raise ArgumentError, "no slave registered for PID #{pid}"
                end
            end

            # @api private
            #
            # Deregisters a slave-to-PID mapping
            #
            # @return [(Autorespawn::Slave,Integer)] the slave object and unique
            #   slave ID that were associated with the slave
            # @raise [ArgumentError] if there is no slave associated with the
            #   PID
            def deregister_slave_pid(pid)
                if (slave = pid_to_slave.delete(pid))
                    [slave, slave_to_id[slave]]
                else
                    raise ArgumentError, "no slave known for #{pid}"
                end
            end

            def initialize(server, manager, io: STDOUT)
                @io = io
                @slave_id = 0
                @slave_to_id = {}
                @pid_to_slave = {}
                manager.on_slave_new do |slave|
                    slave_id = register_slave(slave)
                    io.puts "[##{slave_id}] new slave #{slave_to_s(slave)}"
                end
                manager.on_slave_start do |slave|
                    slave_id = register_slave_pid(slave)
                    io.puts "[##{slave_id}] slave #{slave_to_s(slave)} started (PID=#{slave.pid})"
                end
                manager.on_slave_finished do |slave|
                    slave, slave_id = deregister_slave_pid(slave.pid)
                    io.puts "[##{slave_id}] slave #{slave_to_s(slave)} finished (PID=#{slave.pid})"
                end
                server.on_exception do |pid, exception|
                    slave, slave_id = slave_from_pid(pid)
                    io.puts "[##{slave_id}] #{slave_to_s(slave)} reports exception"
                    Roby.display_exception(io, exception)
                end
                server.on_discovery_start do |pid|
                    slave, slave_id = slave_from_pid(pid)
                    io.puts "[##{slave_id}] #{slave_to_s(slave)} started discovery"
                end
                server.on_discovery_finished do |pid|
                    slave, slave_id = slave_from_pid(pid)
                    io.puts "[##{slave_id}] #{slave_to_s(slave)} finished discovery"
                end
                server.on_test_start do |pid|
                    slave, slave_id = slave_from_pid(pid)
                    io.puts "[##{slave_id}] #{slave_to_s(slave)} started testing"
                end
                server.on_test_result do |pid, file, test_case_name, test_name, failures, assertions, time|
                    _, slave_id = slave_from_pid(pid)
                    io.puts "[##{slave_id}] #{test_case_name}##{test_name}: #{failures.size} failures and #{assertions.size} assertions (#{time})"
                    failures.each do |e|
                        Roby.display_exception(io, e)
                    end
                end
                server.on_test_finished do |pid|
                    slave, slave_id = slave_from_pid(pid)
                    io.puts "[##{slave_id}] #{slave_to_s(slave)} finished testing"
                end
            end
        end
    end
end
