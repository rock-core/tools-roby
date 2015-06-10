require 'qtwebkit'
module Roby
    module LogReplay
        class SchedulerView < Qt::WebView
            def ressources_dir
                File.expand_path(File.dirname(__FILE__))
            end

            def scheduler_view_css
                File.join(ressources_dir, "scheduler_view.css")
            end

            def scheduler_view_rhtml
                File.join(ressources_dir, "scheduler_view.rhtml")
            end

            def erb
                if !@erb
                    template = File.read(scheduler_view_rhtml)
                    @erb = ERB.new(template)
                end
                return @erb
            end

            def format_msg_string(msg, *args)
                args.each_with_index.inject(msg) do |msg, (a, i)|
                    a = if a.respond_to?(:map)
                            a.map(&:to_s).join(", ")
                        else a.to_s
                        end
                    msg.gsub "%#{i + 1}", a
                end
            end

            # Displays the state of the scheduler. It clears existing
            # information
            #
            # @param [Schedulers::State] state the state
            def display(state)
                code = erb.result(binding)
                self.html = code
            end
        end
    end
end
