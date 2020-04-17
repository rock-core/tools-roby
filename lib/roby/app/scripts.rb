# frozen_string_literal: true

require "optparse"
require "roby/standalone"
require "roby/interface"

module Roby
    module App
        module Scripts
            # Common implementation for scripts whose main functionality
            # requires to connect to Roby's remote interface
            #
            # @example basic usage
            #   require 'roby/app/scripts'
            #   Roby::App::Scripts::InterfaceScript.run(*ARGV) do |interface|
            #       # Do stuff with the roby interface
            #   end
            #
            class InterfaceScript
                attr_reader :app

                def initialize(app = Roby.app,
                               default_host: app.shell_interface_host || "localhost",
                               default_port: app.shell_interface_port || Interface::DEFAULT_PORT)
                    @app = app
                    @host_options = Hash[host: default_host, port: default_port]
                end

                def setup_option_parser(parser)
                    Roby::Application.host_options(parser, @host_options)
                end

                def default_option_parser(banner: "")
                    parser = OptionParser.new
                    parser.banner = banner
                    setup_option_parser(parser)
                    parser
                end

                def host
                    @host_options.values_at(:host, :port)
                end

                def run(
                    *args, banner: "",
                    option_parser: default_option_parser(banner: banner)
                )

                    app.guess_app_dir
                    app.shell
                    app.single
                    app.load_base_config

                    args = option_parser.parse(args)
                    host, port = self.host
                    interface = Roby::Interface.connect_with_tcp_to(host, port)
                    yield(interface)
                end

                def self.run(*args, banner: "", &block)
                    Roby.display_exception do
                        begin
                            new.run(*args, banner: banner, &block)
                        rescue Roby::Interface::ConnectionError => e
                            Robot.fatal e.message
                        rescue Interrupt
                            Robot.warn "Interrupted by user"
                        end
                    end
                end
            end
        end
    end
end
