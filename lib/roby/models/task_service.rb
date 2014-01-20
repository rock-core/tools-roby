module Roby
    module Models
        # Ruby (the language) has no support for multiple inheritance. Instead, it
        # uses module to extend classes outside of the class hierarchy.
        #
        # TaskService are the equivalent concept in the world of task models. They
        # are a limited for of task models, which can be used to represent that
        # certain task models have multiple functions.
        #
        # For instance,
        #   
        #   task_service "CameraDriver" do
        #      # CameraDriver is an abstract model used to represent that some tasks
        #      # are providing the services of cameras. They can be used to tag tasks
        #      # that belong to different class hirerachies.
        #      # 
        #      # One can set up arguments on TaskService the same way than class models:
        #      argument :camera_name
        #      argument :aperture
        #      argument :aperture
        #   end
        #
        #   FirewireDriver.provides CameraDriver
        #   # FirewireDriver can now be used in relationships where CameraDriver was
        #   # needed
        class TaskServiceModel < Module
            include MetaRuby::ModelAsModule
            include Arguments

            def clear_model
                super
                argument_set.clear
                argument_defaults.clear
            end

            def match(*args)
                matcher = Queries::TaskMatcher.new
                if args.empty? && self != TaskService
                    matcher.which_fullfills(self)
                else
                    matcher.which_fullfills(*args)
                end
                matcher
            end

            @@local_to_remote = Hash.new
            @@remote_to_local = Hash.new
            def self.local_to_remote; @@local_to_remote end
            def self.remote_to_local; @@remote_to_local end

            class DRoby
                attr_reader :tagdef
                def initialize(tagdef); @tagdef = tagdef end
                def _dump(lvl); @__droby_marshalled__ ||= Marshal.dump(tagdef) end
                def self._load(str); DRoby.new(Marshal.load(str)) end

                def proxy(peer)
                    including = []
                    factory = if peer then peer.method(:local_task_tag)
                              else
                                  DRoby.method(:anon_tag_factory)
                              end

                    tagdef.each do |name, remote_tag|
                        tag = DRoby.local_tag(name, remote_tag, factory) do |tag|
                            including.each { |mod| tag.include mod }
                        end
                        including << tag
                    end
                    including.last
                end

                def self.anon_tag_factory(tag_name)
                    m = Roby::TaskService.new_submodel
                    m.name = tag_name
                    m
                end

                def self.local_tag(name, remote_tag, unknown_model_factory = method(:anon_tag_factory))
                    if !remote_tag.kind_of?(Distributed::RemoteID)
                        remote_tag
                    elsif local_model = TaskServiceModel.remote_to_local[remote_tag]
                        local_model
                    else
                        if name && !name.empty?
                            local_model = constant(name) rescue nil
                        end
                        unless local_model
                            local_model = unknown_model_factory[name]
                            TaskServiceModel.remote_to_local[remote_tag] = local_model
                            TaskServiceModel.local_to_remote[local_model] = [name, remote_tag]
                            yield(local_model) if block_given?
                        end
                        local_model
                    end
                end

                def ==(other)
                    other.kind_of?(DRoby) && 
                        tagdef.zip(other.tagdef).all? { |a, b| a == b }
                end
            end

            def droby_dump(dest)
                unless @__droby_marshalled__
                    tagdef = ancestors.map do |mod|
                        if mod.kind_of?(TaskServiceModel)
                            unless id = TaskServiceModel.local_to_remote[mod]
                                id = [mod.name, mod.remote_id]
                            end
                            id
                        end
                    end
                    tagdef.compact!
                    @__droby_marshalled__ = DRoby.new(tagdef.reverse)
                end
                @__droby_marshalled__
            end
        end

        module TaskServiceDefinitionDSL
            # Define a new task service. When defining the service, one does:
            #
            #   module MyApplication
            #      task_service 'NavigationService' do
            #         argument :target, :type => Eigen::Vector3
            #      end
            #   end
            #
            # Then, to use it:
            #
            #   class GoTo
            #     provides MyApplication::NavigationService
            #   end
            #
            def task_service(name, &block)
                MetaRuby::ModelAsModule.create_and_register_submodel(self, name, TaskService, &block)
            end
        end
        Module.include TaskServiceDefinitionDSL
    end
end

