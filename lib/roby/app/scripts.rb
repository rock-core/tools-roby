require 'optparse'
require 'roby/standalone'
require 'roby/interface'

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
                attr_reader :host

                def initialize(app = Roby.app)
                    @app = app
                    @host_options = Hash.new
                end

                def setup_option_parser(parser)
                    @host_options = Hash.new
                    Roby::Application.host_options(parser, @host_options)
                end

                def default_option_parser(banner: "")
                    parser = OptionParser.new
                    parser.banner = banner
                    setup_option_parser(parser)
                    parser
                end

                def with_setup
                    app.base_setup
                    yield
                end

                def host
                    remote_url = @host_options[:host] || app.droby['host'] || 'localhost'
                    if remote_url !~ /:\d+$/
                        if app.droby['host'] && app.droby['host'] =~ /(:\d+)$/
                            remote_url << $1
                        else
                            remote_url << ":#{Roby::Interface::DEFAULT_PORT}"
                        end
                    end

                    match = /(.*):(\d+)$/.match(remote_url)
                    if !match
                        raise ArgumentError, "malformed URL #{remote_url}"
                    end

                    return match[1], Integer(match[2])
                end

                def run(*args, banner: "",
                    option_parser: default_option_parser(banner: banner))

                    app.guess_app_dir
                    app.shell
                    app.single

                    args = option_parser.parse(args)
                    with_setup do
                        host, port = self.host
                        interface = Roby::Interface.connect_with_tcp_to(host, port)
                        yield(interface)
                    end
                end

                def self.run(*args, banner: '', &block)
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

