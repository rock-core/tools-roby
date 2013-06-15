module Roby
    module Actions
        class Script < ActionCoordination
            extend Models::ActionCoordination
            extend Models::Script
            include ScriptBase

            class TimedOut < LocalizedError
                attr_reader :instruction

                def initialize(task, instruction)
                    super(task)
                    @instruction = instruction
                end
            end

            class TimeoutStart < ScriptInstruction
                attr_reader :model
                attr_reader :event
                attr_accessor :timeout_stop

                def initialize(model, event)
                    @model = model
                    @event = event
                end

                def execute(script)
                    script.root_task.plan.engine.delayed(model.seconds) do
                        if !self.disabled?
                            # Remove all instructions that are within the
                            # timeout's scope
                            if event
                                event.resolve.emit
                                script.jump_to(timeout_stop)
                            else
                                raise TimedOut.new(script.root_task, script.current_instruction), "#{script.current_instruction} timed out"
                            end
                        end
                    end
                end
            end

            class TimeoutStop < ScriptInstruction
                attr_reader :timeout_start

                def initialize(timeout_start)
                    @timeout_start = timeout_start
                    timeout_start.timeout_stop = self
                end

                def execute(script)
                    timeout_start.cancel
                end
            end

            # The list of instructions, instanciated from model.instructions
            # using {ActionCoordination#instance_for}
            attr_reader :instructions

            # The current instruction
            attr_reader :current_instruction

            def initialize(action_interface_model, root_task, arguments = Hash.new)
                super
                prepare

                root_task.execute do
                    step
                end
            end
        end
    end
end

