require 'rubigen'
module Roby
    module App
        class GenBase < RubiGen::Base
            module RecorderExtension
                def directory(relative_destination)
                    super(App.resolve_robot_in_path(relative_destination))
                end
                def file(relative_source, relative_destination, file_options = Hash.new, &block)
                    relative_destination = App.resolve_robot_in_path(relative_destination)
                    super(relative_source, relative_destination, file_options, &block)
                end
                def template(template, dest, *args, &block)
                    super(template, App.resolve_robot_in_path(dest), *args, &block)
                end
            end

            def initialize(runtime_args, runtime_options = Hash.new)
                super
                usage if args.empty?

                Roby.app.require_app_dir
                @destination_root = Roby.app.app_dir
            end

            def record
                super() do |m|
                    m.extend RecorderExtension
                    yield(m)
                end
            end

            # Helper to handle opening and closing modules
            #
            # @return [(String,String,String)] the indentation string for the
            #   module's content, the code necessary to open the module and the
            #   code to close it
            #
            # @example usually used in e.g. ERB with
            #   <% indent, open, close = Roby::App::GenBase.in_module("A", "Module") %>
            #   <%= open %>
            #   <%= indent %>class MyClass
            #   <%= indent %>    it_does_something
            #   <%= indent %>end
            #   <%= close %>
            #
            def self.in_module(*module_path)
                indent = ""
                open_code  = []
                close_code = []
                module_path.each do |m|
                    open_code.push "#{indent}module #{m}"
                    close_code.unshift "#{indent}end"
                    indent = indent + "    "
                end
                return indent, open_code.join("\n"), close_code.join("\n")
            end
        end
    end
end
