module Roby
    module YARD
        include ::YARD

        class ModelAttributeListHandler < YARD::Handlers::Ruby::AttributeHandler
            handles method_call(:model_attribute_list)
            namespace_only

            def process
                name = statement.parameters[0].jump(:tstring_content, :ident).source
                key_type, value_type = Utilrb::YARD::InheritedAttributeHandler.
                    process(self, "#{name}_set", "#{name}_sets", true)

                push_state(:scope => :class) do
                    object = YARD::CodeObjects::MethodObject.new(namespace, "#{name}s", scope)
                    object.dynamic = true 
                    register(object)
                    object.parameters << ["source_event", "Symbol"]
                    object.docstring.replace("The set of #{name}s originating from source_event that should be registered on all instances of this task model.\n@return [ValueSet<#{value_type}>] the set of event models")

                    object = YARD::CodeObjects::MethodObject.new(namespace, "each_#{name}", scope)
                    object.dynamic = true 
                    register(object)
                    object.parameters << ["source_event", "Symbol"]
                    object.docstring.replace("Enumerates all the #{name}s declared on this task model that originates from the given event generator\n@yield [target_event]\n@yieldparam [#{value_type}] target_event\n@return []")

                    object = YARD::CodeObjects::MethodObject.new(namespace, "all_#{name}s", scope)
                    object.dynamic = true 
                    register(object)
                    object.parameters << ["source_event", "Symbol"]
                    object.docstring.replace("All the #{name}s that should be registered on all instances of this task model.\n@return [Hash<#{key_type},ValueSet<#{value_type}>>")
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

    end
end

