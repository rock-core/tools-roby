# frozen_string_literal: true

require "roby/app/cucumber"

module Roby
    module App
        module Cucumber
            module World
                attr_reader :roby_controller

                def roby_world_initialize
                    @roby_controller = Controller.new
                end

                def self.extend_object(world)
                    super
                    world.roby_world_initialize
                end
            end
        end
    end
end

After do |scenario|
    if kind_of?(Roby::App::Cucumber::World) && roby_controller.roby_running?
        if roby_controller.roby_connected? # failed to connect, kill forcefully
            roby_controller.roby_stop
        else
            roby_controller.roby_kill
        end
    end
end
