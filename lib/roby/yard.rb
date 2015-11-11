require 'facets/string/camelcase'
module Roby
    module YARD
        include ::YARD

        class ModelRelationHandler < YARD::Handlers::Ruby::Base
            handles method_call(:model_relation)
            namespace_only

            def register(object)
                super
                register_group(object, "Event Relations")
            end

            def process
                name = statement.parameters[0].jump(:tstring_content, :ident).source

                push_state(:scope => :class) do
                    object = YARD::CodeObjects::MethodObject.new(namespace, "#{name}_sets", scope)
                    object.dynamic = true 
                    register(object)
                    object.docstring.replace(
                        YARD::Docstring.new("The set of #{name}s defined at this level of the model hierarchy") +
                        object.docstring)
                    object.docstring.add_tag(
                        *YARD::Docstring.parser.create_tag("return", "[Hash<Symbol,Set<Symbol>>]"))

                    object = YARD::CodeObjects::MethodObject.new(namespace, "each_#{name}_set", scope)
                    object.dynamic = true 
                    register(object)
                    object.docstring.add_tag(
                        *YARD::Docstring.parser.create_tag("yieldparam", "[Symbol] source_name"),
                        *YARD::Docstring.parser.create_tag("yieldparam", "[Set<Symbol>] target_names"))

                    object = YARD::CodeObjects::MethodObject.new(namespace, "#{name}s", scope)
                    object.dynamic = true 
                    register(object)
                    object.parameters << ["model", nil]
                    object.docstring.add_tag(
                        *YARD::Docstring.parser.create_tag("param", "[Symbol] event_name"),
                        *YARD::Docstring.parser.create_tag("return", "[Set<Symbol>] target #{name}s"))

                    object = YARD::CodeObjects::MethodObject.new(namespace, "each_#{name}", scope)
                    object.dynamic = true 
                    register(object)
                    object.parameters << ["model", nil]
                    object.docstring.add_tag(
                        *YARD::Docstring.parser.create_tag("param", "[Symbol] event_name"),
                        *YARD::Docstring.parser.create_tag("yieldparam", "[Symbol] target_name"))

                    object = YARD::CodeObjects::MethodObject.new(namespace, "all_#{name}s", scope)
                    object.dynamic = true 
                    register(object)
                    object.parameters << ["model", nil]
                    object.docstring.replace(
                        YARD::Docstring.new("The set of #{name}s that will be applied on all instances of this model") +
                        object.docstring)
                    object.docstring.add_tag(
                        *YARD::Docstring.parser.create_tag("return", "[Hash<Symbol,Set<Symbol>>]"))
                end
            end
        end

        class RelationHandler < YARD::Handlers::Ruby::AttributeHandler
            handles method_call(:relation)
            namespace_only

            def process
                name = statement.parameters[0].jump(:tstring_content, :ident).source


                graph_class = YARD::CodeObjects::ClassObject.new(namespace, "#{name}GraphClass")
                register(graph_class)
                instance_module = YARD::CodeObjects::ModuleObject.new(graph_class, "Extension")
                register(instance_module)
                class_module = YARD::CodeObjects::ModuleObject.new(graph_class, "ClassExtension")
                register(class_module)

            end
        end

        class TaskServiceHandler < YARD::Handlers::Ruby::Base
            handles method_call(:task_service)
            namespace_only

            def process
                name = statement.parameters[0].jump(:tstring_content, :ident).source

                service_module = YARD::CodeObjects::ModuleObject.new(namespace, name)
                register(service_module)
                parse_block(statement.last.last, namespace: service_module)
                service_module.dynamic = true
            end
        end

        class ArgumentHandler < YARD::Handlers::Ruby::Base
            handles method_call(:argument)
            namespace_only

            def process
                name = statement.parameters[0].jump(:tstring_content, :ident).source

                default = nil
                if statement.parameters[1]
                    statement.parameters[1].jump(:assoc).to_a.each_slice(2) do |key, value|
                        if key.source == 'default:'
                            default = value.source
                        end
                    end
                end

                writer = YARD::CodeObjects::MethodObject.new(namespace, "#{name}=")
                register(writer)
                register_group(writer, "Task Arguments")

                reader = YARD::CodeObjects::MethodObject.new(namespace, name)
                register(reader)
                register_group(reader, "Task Arguments")
                reader.docstring = "Default: #{default}" if default && reader.docstring.blank?(false)
            end
        end

        class EventHandler < YARD::Handlers::Ruby::Base
            handles method_call(:event)
            namespace_only

            def process
                name = statement.parameters[0].jump(:tstring_content, :ident).source

                controlable = false
                if statement.parameters[1]
                    statement.parameters[1].jump(:assoc).to_a.each_slice(2) do |key, value|
                        if key.source == 'controlable:' || key.source == "command:"
                            controlable = true
                        end
                    end
                end

                accessor = YARD::CodeObjects::MethodObject.new(namespace, "#{name}_event")
                register(accessor)
                register_group(accessor, "Task Events")
                accessor.docstring.add_tag(
                    *YARD::Docstring.parser.create_tag("return", "[EventGenerator]"))

                happened = YARD::CodeObjects::MethodObject.new(namespace, "#{name}?")
                register(happened)
                register_group(happened, "Task Events")
                happened.docstring.add_tag(
                    *YARD::Docstring.parser.create_tag("return", "[Boolean]"))

                if controlable
                    command = YARD::CodeObjects::MethodObject.new(namespace, "#{name}!")
                    register(command)
                    register_group(command, "Task Events")
                    command.parameters << ['context', 'nil']
                end

                push_state(scope: :class) do
                    event_class = YARD::CodeObjects::ClassObject.new(namespace, "#{name.camelcase(true)}")
                    register(event_class)
                    event_class.docstring.replace(
                        YARD::Docstring.new("Event class used to represent the events emitted by #{namespace}##{name}_event\n\n") +
                        event_class.docstring)
                end
            end
        end
    end
end

