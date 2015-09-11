module Roby
    module Distributed
        # A minimal object manager compatible with the needs of
        # marshalling/demarshallin through DRoby
        module DumbManager
            def local_object(obj)
                if obj.respond_to?(:proxy)
                    obj.proxy(self)
                else obj
                end
            end

            def local_task_tag(*args)
                Roby::Models::TaskServiceModel::DRoby.anon_tag_factory(*args)
            end

            def local_model(*args)
                Distributed::DRobyModel.anon_model_factory(*args)
            end

            def connection_space
                Roby
            end

            def incremental_dump?(*)
                false
            end

            extend DumbManager
        end
    end
end

