# frozen_string_literal: true

SimpleCov.command_name "roby"
SimpleCov.start do
    add_filter "/test/"
    add_filter "/gui/"
    add_filter "/scripts/"
    coverage_dir "coverage/simplecov"
end

require "roby"
