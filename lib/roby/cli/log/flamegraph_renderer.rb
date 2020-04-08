# frozen_string_literal: true

# inspired by https://github.com/brendangregg/FlameGraph
require "base64"

module Roby
    module CLI
        class Log
            class FlamegraphRenderer
                def initialize(stacks)
                    @stacks = stacks
                end

                def graph_html(embed_resources: false)
                    body = read("flamegraph.html")
                    body.sub! "/**INCLUDES**/",
                              if embed_resources
                                  embed("jquery.min.js", "d3.min.js", "lodash.min.js")
                              else
                                  '<script src="https://cdnjs.cloudflare.com/ajax/libs/jquery/1.9.1/jquery.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/d3/3.0.8/d3.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/lodash.js/1.3.1/lodash.min.js"></script>'
                              end

                    body.sub!("/**DATA**/", ::JSON.generate(graph_data))
                    body
                end

                def graph_data
                    table = []
                    prev = []

                    x = 0
                    # a 2d array makes collapsing easy
                    @stacks.each_with_index do |(stack, duration), pos|
                        col = []
                        stack.each_with_index do |frame, i|
                            if (last_col = prev[i]) && (last_col[0] == frame)
                                last_col[1] += duration
                                col << nil
                            else
                                prev[i] = [frame, duration]
                                col << prev[i]
                            end
                        end
                        prev = prev[0..col.length - 1].to_a
                        table << [x, col]
                        x += duration
                    end

                    data = []

                    # a 1d array makes rendering easy
                    col_num = 0
                    table.each do |x, col|
                        col.each_with_index do |row, row_num|
                            next unless row && row.length == 2

                            data << {
                                x: x + 1,
                                y: row_num + 1,
                                width: row[1],
                                frame: row[0]
                            }
                            col_num += row[1]
                        end
                    end

                    data
                end

                private

                def embed(*files)
                    out = String.new
                    files.each do |file|
                        body = read(file)
                        out << "<script src='data:text/javascript;base64," << Base64.encode64(body) << "'></script>"
                    end
                    out
                end

                def read(file)
                    IO.read(::File.expand_path(file, ::File.dirname(__FILE__)))
                end
            end
        end
    end
end
