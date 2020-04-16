# frozen_string_literal: true

require "roby"
require "optparse"
require "rb-readline"

app = Roby.app
app.guess_app_dir
app.shell
app.single
app.load_base_config

require "pp"

silent = false
opt = OptionParser.new do |opt|
    opt.on "--silent", "disable notifications (can also be controlled in the shell itself)" do
        silent = true
    end
end

host_options = {}
Roby::Application.host_options(opt, host_options)
opt.parse! ARGV

host, port = host_options.values_at(:host, :port)

require "irb"
require "irb/ext/save-history"
IRB.setup("#{host}:#{port}")
IRB.conf[:INSPECT_MODE] = false
IRB.conf[:IRB_NAME]     = "#{host}:#{port}"
IRB.conf[:USE_READLINE] = true
IRB.conf[:PROMPT_MODE]  = :ROBY
IRB.conf[:AUTO_INDENT] = true
if Roby.app.app_dir
    IRB.conf[:HISTORY_FILE] = File.join(Roby.app.app_dir, "config", "shell_history")
end
IRB.conf[:SAVE_HISTORY] = 1000
IRB.conf[:PROMPT][:ROBY] = {
    :PROMPT_I => "%N > ",
    :PROMPT_N => "%N > ",
    :PROMPT_S => "%N %l ",
    :PROMPT_C => "%N * ",
    :RETURN => "=> %s\n"
}

main_remote_interface__ =
    begin
        Roby::Interface::ShellClient.new("#{host}:#{port}") do
            Roby::Interface.connect_with_tcp_to(host, port)
        end
    rescue Interrupt
        Roby::Interface.warn "Interrupted by user"
        exit(1)
    end

main_remote_interface__.silent(silent)

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
        actions = main_remote_interface__.client.actions.find_all do |act|
            prefix_match === act.name
        end
        unless actions.empty?
            return actions.map { |act| "#{act.name}!" }
        end
    end
    return []
end

class ShellEvalContext < BasicObject
    include ::Kernel

    WHITELISTED_METHODS = %i[actions wtf? cancel safe unsafe safe? help]
        .freeze

    def initialize(interface, send_q: ::Queue.new, results_q: ::Queue.new)
        @__interface = interface
        @__send = send_q
        @__results = results_q
    end

    def respond_to_missing?(m, include_private)
        @__interface.respond_to?(m, include_private)
    end

    def method_missing(m, *args, &block)
        if WHITELISTED_METHODS.include?(m)
            return @__interface.send(m, *args, &block)
        end

        @__send.push(::Kernel.lambda do
            @__interface.send(m, *args, &block)
        end)
        result, error = @__results.pop
        if error
            raise error
        elsif result.kind_of?(::Roby::Interface::ShellSubcommand)
            ::ShellEvalContext.new(result, send_q: @__send, results_q: @__results)
        else
            result
        end
    end

    def process_pending
        loop do
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
    # Make main_remote_interface__ the top-level object
    shell_context__ = ShellEvalContext.new(main_remote_interface__)
    ws = IRB::WorkSpace.new(shell_context__.instance_eval { binding })
    irb = IRB::Irb.new(ws)

    output_sync = Mutex.new
    context = IRB::Context.new(irb, ws, SynchronizedReadlineInput.new(output_sync))
    context.save_history = 100
    IRB.conf[:MAIN_CONTEXT] = irb.context

    Thread.new do
        begin
            main_remote_interface__.notification_loop(0.1) do |connected, messages|
                shell_context__.process_pending

                begin
                    unless main_remote_interface__.silent?
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
