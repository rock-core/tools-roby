require 'thor'
require 'roby'
require 'roby/cli/exceptions'
require 'roby/cli/gen_main'

module Roby
    module CLI
        class Main < Thor
            desc 'Deprecated', "use 'gen robot' instead"
            def add_robot(robot_name)
                gen('robot', robot_name)
            end

            desc 'Deprecated', "use 'gen app' instead"
            def init
                gen('app')
            end

            desc 'gen [GEN_MODE]', 'scaffold generation'
            subcommand :gen, GenMain
        end
    end
end

