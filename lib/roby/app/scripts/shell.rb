require 'roby'
require 'optparse'
require 'rb-readline'

app = Roby.app
app.guess_app_dir
app.shell
app.single
app.load_base_config

require 'pp'

silent = false
opt = OptionParser.new do |opt|
    opt.on '--silent', 'disable notifications (can also be controlled in the shell itself)' do
        silent = true
    end
end

host_options = Hash.new
Roby::Application.host_options(opt, host_options)
opt.parse! ARGV

host, port = host_options.values_at(:host, :port)

require 'irb'
require 'irb/ext/save-history'
IRB.setup("#{host}:#{port}")
IRB.conf[:INSPECT_MODE] = false
IRB.conf[:IRB_NAME]     = "#{host}:#{port}"
IRB.conf[:USE_READLINE] = true
IRB.conf[:PROMPT_MODE]  = :ROBY
IRB.conf[:AUTO_INDENT] = true
if Roby.app.app_dir
    IRB.conf[:HISTORY_FILE] = File.join(Roby.app.app_dir, 'config', 'shell_history')
end
IRB.conf[:SAVE_HISTORY] = 1000
IRB.conf[:PROMPT][:ROBY] = {
    :PROMPT_I => "%N > ",
    :PROMPT_N => "%N > ",
    :PROMPT_S => "%N %l ",
    :PROMPT_C => "%N * ",
    :RETURN => "=> %s\n"
}

__main_remote_interface__ = 
    begin
        Roby::Interface::ShellClient.new("#{host}:#{port}") do
            Roby::Interface.connect_with_tcp_to(host, port)
        end
    rescue Interrupt
        Roby::Interface.warn "Interrupted by user"
        exit(1)
    end

__main_remote_interface__.silent(silent)

module RbReadline
    def self.puts(msg)
        if needs_save_and_restore = rl_isstate(RL_STATE_READCMD)
            saved_point = rl_point
            rl_maybe_save_line
            rl_save_prompt
            rl_kill_full_line(nil, nil)
            rl_redisplay
        end

        Kernel.puts msg

        if needs_save_and_restore
            rl_restore_prompt
            rl_maybe_replace_line
            @rl_point = saved_point
            rl_redisplay
        end
    end
end

class SynchronizedReadlineInput < IRB::ReadlineInputMethod
    def initialize(mutex)
        @mutex = mutex
        super()
    end

    def gets
        mutex.synchronize { super }
    end
end

Readline.completer_word_break_characters = ""
Readline.completion_proc = lambda do |string|
    if string =~ /^\w+$/
        prefix_match = /^#{string}/
        actions = __main_remote_interface__.client.actions.find_all do |act|
            prefix_match === act.name
        end
        if !actions.empty?
            return actions.map { |act| "#{act.name}!" }
        end
    end
    return Array.new
end

class ShellEvalContext < BasicObject
    include ::Kernel

    def initialize(interface)
        @__interface = interface
        @__send = ::Queue.new
        @__results = ::Queue.new
    end

    def respond_to_missing?(m, include_private)
        @__interface.respond_to?(m, include_private)
    end

    def method_missing(m, *args, &block)
        @__send.push(::Kernel.lambda { @__interface.send(m, *args, &block) })
        result, error = @__results.pop
        if error
            raise error
        else result
        end
    end

    def process_pending
        while true
            begin
                command = @__send.pop(true)
                begin
                    result = command.call
                    @__results.push([result, nil])
                rescue ::Exception => e
                    @__results.push([nil, e])
                end
            rescue ::ThreadError
                break
            end
        end
    end
end

begin
    # Make __main_remote_interface__ the top-level object
    __shell_context__ = ShellEvalContext.new(__main_remote_interface__)
    ws  = IRB::WorkSpace.new(__shell_context__.instance_eval { binding })
    irb = IRB::Irb.new(ws)

    output_sync = Mutex.new
    context = IRB::Context.new(irb, ws, SynchronizedReadlineInput.new(output_sync))
    context.save_history = 100
    IRB.conf[:MAIN_CONTEXT] = irb.context

    to_process, process_result = Queue.new, Queue.new
    Thread.new do
        begin
            __main_remote_interface__.notification_loop(0.1) do |connected, messages|
                __shell_context__.process_pending

                begin
                    if !__main_remote_interface__.silent?
                        output_sync.synchronize do
                            messages.each { |msg| RbReadline.puts(msg) }
                        end
                    end
                rescue Exception => e
                    puts "Shell notification thread error:"
                    puts e
                    puts e.backtrace.join("\n")
                end
            end
        rescue Exception => e
            puts "Shell notification thread TERMINATED because of exception"
            puts e
            puts e.backtrace.join("\n")
        end
    end

    trap("SIGINT") do
        irb.signal_handle
    end
    catch(:IRB_EXIT) do
        irb.eval_input
    end
end

