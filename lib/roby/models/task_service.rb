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
                argument_set.clear
                argument_defaults.clear
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
        Module.extend TaskServiceDefinitionDSL
    end
end

