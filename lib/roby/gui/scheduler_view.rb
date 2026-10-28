# frozen_string_literal: true

require "erb"
require "cgi"

module Roby
    module GUI
        # View for scheduling-related log events
        class SchedulerView < Qt::Widget
            def initialize(*)
                super

                @text_view = Qt::TextBrowser.new
                @text_view.read_only = true
                @text_view.accept_rich_text = true
                @layout = Qt::VBoxLayout.new(self)
                @layout.add_widget(@text_view)
            end

            def resources_dir
                File.expand_path(__dir__)
            end

            def scheduler_view_rhtml
                File.join(resources_dir, "scheduler_view.html.erb")
            end

            def erb
                unless @erb
                    template = File.read(scheduler_view_rhtml)
                    @erb = ERB.new(template)
                end
                @erb
            end

            def format_pp(object)
                object_s = CGI.escapeHTML(PP.pp(object, +""))
                "<pre>#{object_s}</pre>"
            end

            def format_msg_string(msg, *args)
                string = args.each_with_index.inject(msg) do |updated_msg, (a, i)|
                    a = if a.respond_to?(:map)
                            a.map(&:to_s).join(", ")
                        else
                            a.to_s
                        end
                    updated_msg.gsub "%#{i + 1}", a
                end
                CGI.escapeHTML(string)
            end

            # Displays the state of the scheduler. It clears existing
            # information
            #
            # @param [Schedulers::State] state the state
            def display(state)
                code = erb.result(binding)
                return if @code == code

                scroll_position = @text_view.vertical_scroll_bar.slider_position
                puts code
                @code = @text_view.html = code
                @text_view.vertical_scroll_bar.slider_position = scroll_position
            end

            def contents_height
                size_hint.height
            end
        end
    end
end
