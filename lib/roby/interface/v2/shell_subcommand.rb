# frozen_string_literal: true

module Roby
    module Interface
        module V2
            # Representation of a subcommand on {Interface} on the shell side
            class ShellSubcommand < SubcommandClient
                def call(options, path, m, *args)
                    parent.call(options, [name] + path, m, *args)
                end

                def method_missing(m, *args)
                    parent.call({}, [name], m, *args)
                rescue NoMethodError => e
                    if e.message =~ /undefined method .#{m}./
                        puts "invalid command name #{m}, " \
                             "call 'help #{path.join('.')}' for more information"
                    else
                        raise
                    end
                rescue ArgumentError => e
                    if e.message =~ /wrong number of arguments/ &&
                       e.backtrace.first =~ /#{m}/
                        puts e.message
                    else
                        raise
                    end
                end
            end
        end
    end
end
