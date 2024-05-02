# frozen_string_literal: true

require "roby/cli/exceptions"

module Roby
    module CLI
        module Gen
            # Helper methods for generator actions and templates
            #
            # The module is used to extend {Gen}. Its methods are usually
            # accessed as singletong methods on {Gen}, e.g. {Gen.resolve_name}.
            module Helpers
                # Resolve a user-given model name into the corresponding file path
                # and namespace path
                #
                # Both paths are returned relative to the given roots
                #
                # @raise InconsistenName if parts of the given name are
                #   inconsistent with the given roots
                #
                # @example
                #   resolve_names('models/actions/navigation.rb',
                #                 ['models', 'actions'],
                #                 ['Actions']) # => [['navigation.rb'], ['Navigation']]
                #   resolve_names('models/tasks/navigation/goto.rb',
                #                 ['models', 'tasks'],
                #                 ['Tasks'])
                #           # => [['navigation/goto.rb'], ['Navigation', 'Goto']]
                #   resolve_names('models/tasks/navigation/goto.rb',
                #                 ['models', 'actions'],
                #                 ['Actions'])
                #           # => raise, as models/actions must be the path root
                def resolve_name(
                    gen_type, given_name, robot_name, file_root, namespace_root
                )
                    if given_name =~ /\// || given_name[0, 1] !~ /[A-Z]/
                        resolve_name_as_path(
                            gen_type, given_name, robot_name, file_root, namespace_root
                        )
                    else
                        resolve_name_as_constant(
                            gen_type, given_name, robot_name, file_root, namespace_root
                        )
                    end
                end

                # @api private
                #
                # Helper for {#resolve_name}
                def resolve_name_as_path(
                    gen_type, given_name, robot_name, file_root, namespace_root
                )
                    file_name = given_name.split("/")
                    non_matching_prefix = file_root.each_with_index.find do |p, i|
                        file_name[i] != p
                    end
                    if non_matching_prefix
                        if non_matching_prefix[1] == 0
                            file_name = file_root + file_name
                        else
                            raise CLIInvalidArguments,
                                  "attempted to create a #{gen_type} model " \
                                  "outside of #{file_root.join('/')}"
                        end
                    end

                    if robot_name && file_name[-2] != robot_name
                        raise CLIInvalidArguments,
                              "attempted to create a model for robot #{robot_name} " \
                              "outside a #{robot_name}/ subfolder"
                    end

                    file_name[-1] = File.basename(file_name[-1], ".rb")
                    file_name_without_root = file_name[file_root.size..-1]

                    app_module_name = Roby.app.module_name.split("::")
                    class_without_app =
                        namespace_root +
                        file_name_without_root.map { |n| n.camelcase(:upper) }
                    class_name = app_module_name + class_without_app
                    [file_name_without_root, class_name]
                end

                # @api private
                #
                # Helper for {#resolve_name}
                def resolve_name_as_constant(
                    gen_type, given_name, robot_name, file_root, namespace_root
                )
                    robot_module =
                        if robot_name
                            [robot_name.camelcase(:upper)]
                        else
                            []
                        end

                    given_class_name = given_name.split("::")
                    app_module_name = Roby.app.module_name.split("::")
                    full_namespace_root = app_module_name + namespace_root

                    non_matching_full_prefix =
                        full_namespace_root.each_with_index.find do |p, i|
                            given_class_name[i] != p
                        end

                    if non_matching_full_prefix
                        if non_matching_full_prefix[1] == 0
                            non_matching_app_prefix =
                                namespace_root.each_with_index.find do |p, i|
                                    given_class_name[i] != p
                                end
                            if non_matching_app_prefix
                                if non_matching_app_prefix[1] == 0
                                    given_class_name =
                                        full_namespace_root + given_class_name
                                else
                                    raise CLIInvalidArguments,
                                          "attempted to create a #{gen_type} model " \
                                          "outside of its expected namespace " \
                                          "#{full_namespace_root.join('::')}"
                                end
                            else
                                given_class_name =
                                    app_module_name + given_class_name
                            end
                        else
                            raise CLIInvalidArguments,
                                  "attempted to create a #{gen_type} model outside " \
                                  "of its expected namespace " \
                                  "#{full_namespace_root.join('::')}"
                        end
                    end

                    if robot_name && given_class_name[-2, 1] != robot_module
                        raise CLIInvalidArguments,
                              "attempted to create a model for robot #{robot_name} " \
                              "outside the expected namespace " \
                              "#{robot_module.join('::')} " \
                              "(e.g. #{given_class_name[0..-2].join('::')}" \
                              "::#{robot_module.join('::')}" \
                              "::#{given_class_name[-1]})"
                    end

                    file_name = given_class_name[full_namespace_root.size..-1]
                                .map { |camel| pathize(camel) }
                    [file_name, given_class_name]
                end

                # @api private
                #
                # Helper class to render a template in a controlled context
                class Context
                    def initialize(vars)
                        @vars = vars
                    end

                    def method_missing(m)
                        @vars.fetch(m.to_s)
                    end

                    def context
                        binding
                    end
                end

                # @api private
                #
                # Generate a context that be given to the context: argument to
                # Thor's template action
                def make_context(vars)
                    Context.new(vars).context
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
                def in_module(*module_path)
                    indent = ""
                    open_code = []
                    close_code = []
                    last_module_i = module_path.size - 1
                    module_path.each_with_index do |m, i|
                        nodoc = " #:nodoc:" if i == last_module_i
                        open_code.push "#{indent}module #{m}#{nodoc}"
                        close_code.unshift "#{indent}end"
                        indent += "    "
                    end
                    [indent, open_code.join("\n"), close_code.join("\n")]
                end

                # Converts an input string that is in camelcase into a path string
                #
                # NOTE: Facets' String#pathize and String#snakecase have corner
                # cases that really don't work for us:
                #   '2D'.snakecase => '2_d'
                #   'GPS'.pathize => 'gp_s'
                #
                def pathize(string)
                    string
                        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                        .gsub(/([a-z])([A-Z][a-z])/, '\1_\2')
                        .gsub("__", "/")
                        .gsub("::", "/")
                        .gsub(/\s+/, "") # spaces are bad form
                        .gsub(/[?%*:|"<>.]+/, "") # reserved characters
                        .downcase
                end

                class Base
                    def initialize(robot_name)
                        @robot_name = robot_name
                    end
                end
            end

            extend Helpers
        end
    end
end
