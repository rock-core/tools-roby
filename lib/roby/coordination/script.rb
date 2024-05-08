# frozen_string_literal: true

module Roby
    module Coordination
        # Common logic for script-based coordination models
        module Script
            DeadInstruction = Models::Script::DeadInstruction

            class BlockExecute < ScriptInstruction
                attr_reader :task, :block

                def initialize(block)
                    super()

                    @block = block
                end

                def new(task)
                    @task = task
                    self
                end

                def execute(script)
                    script.root_task.instance_eval(&block)
                    true
                end
            end

            module Models
                class PollUntil
                    attr_reader :event, :block

                    def initialize(event, block)
                        @event = event
                        @block = block
                    end

                    def new(script)
                        Script::PollUntil.new(
                            script.root_task,
                            script.instance_for(event),
                            block
                        )
                    end
                end
            end

            class PollUntil < ScriptInstruction
                attr_reader :root_task, :event, :block

                def initialize(root_task, event, block)
                    super()

                    @root_task = root_task
                    @event = event
                    @block = block
                end

                def cancel
                    root_task.remove_poll_handler(@poll_handler_id) if @poll_handler_id
                    super
                end

                def execute(script)
                    @poll_handler_id = root_task.poll do
                        root_task.instance_eval(&block)
                    end
                    event = self.event.resolve
                    event.once(on_replace: :copy) do |ev|
                        if !disabled? && ev.generator == self.event.resolve
                            cancel
                            script.step
                        end
                    end

                    root_task = script.root_task
                    event_task = event.task
                    if (event_task != root_task) && !root_task.depends_on?(event_task)
                        root_task.depends_on event_task, success: event.symbol
                    else
                        event.when_unreachable(true) do |reason, _generator|
                            unless disabled?
                                raise Script::DeadInstruction.new(script.root_task),
                                      "the 'until' condition of #{self} will " \
                                      "never be reached: #{reason}"
                            end
                        end
                    end

                    false
                end
            end

            # Exception generated when a timeout block has reached its specified
            # limit, if the :event argument has not been set
            class TimedOut < LocalizedError
                attr_reader :instruction

                def initialize(task, instruction)
                    super(task)
                    @instruction = instruction
                end
            end

            class TimeoutStart < ScriptInstruction
                attr_reader :model, :event
                attr_accessor :timeout_stop

                def initialize(model, event)
                    super()

                    @model = model
                    @event = event
                end

                def execute(script)
                    script.root_task.execution_engine.delayed(model.seconds) do
                        unless disabled?
                            # Remove all instructions that are within the
                            # timeout's scope
                            if event
                                event.resolve.emit
                                script.jump_to(timeout_stop)
                            else
                                e = TimedOut.new(
                                    script.root_task, script.current_instruction
                                )
                                e = e.exception("#{script.current_instruction} timed out")
                                script.root_task.execution_engine.add_error(e)
                            end
                        end
                    end
                    true
                end
            end

            class TimeoutStop < ScriptInstruction
                attr_reader :timeout_start

                def initialize(timeout_start)
                    super()

                    @timeout_start = timeout_start
                    timeout_start.timeout_stop = self
                end

                def execute(_script)
                    timeout_start.cancel
                    true
                end
            end

            attr_reader :current_instruction, :instructions

            def prepare
                @instructions = []
                resolve_instructions
                @current_instruction = nil

                root_task.stop_event.on do |_context|
                    current_instruction&.cancel
                    instructions.each(&:cancel)
                end
            end

            def resolve_instructions
                model.instructions.each do |ins|
                    instructions << instance_for(ins)
                end
            end

            def dependency_options_for(toplevel, task, roles)
                options = super
                if current_instruction.respond_to?(:task) &&
                   current_instruction.task == task
                    options = options.merge(current_instruction.dependency_options)
                end
                options
            end

            def step
                return if current_instruction && !current_instruction.disabled?

                while (@current_instruction = instructions.shift)
                    next if current_instruction.disabled?

                    break unless current_instruction.execute(self)
                end
            rescue LocalizedError => e
                raise e
            rescue Exception => e # rubocop:disable Lint/RescueException
                raise CodeError.new(e, root_task), e.message, e.backtrace
            end

            def jump_to(target)
                # Verify that the jump is valid
                if current_instruction != target && !instructions.include?(target)
                    raise ArgumentError, "#{target} is not an instruction in #{self}"
                end

                current_instruction.cancel if current_instruction != target
                instructions.shift while instructions.first != target
                step
            end

            def finished?
                instructions.empty? && !@current_instruction
            end
        end
    end
end
