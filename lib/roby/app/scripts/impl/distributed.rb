require File.join(APP_DIR, 'config', 'init.rb')
require 'roby/distributed/connection_space'
require 'roby/distributed/protocol'

include Roby
include DRb
include Rinda

host = DISCOVERY['tuplespace']
if !host
    STDERR.puts "Centralized network discovery disabled, nothing to do"
    exit
end

Thread.abort_on_exception = true
TEMPLATE = [:host, nil, nil, nil]

ts = Rinda::TupleSpace.new
DRb.start_service "roby://#{host}", ts

new_db = ts.notify('write', TEMPLATE)
take_db = ts.notify('take', TEMPLATE)

Thread.start do
    new_db.each { |_, t| STDERR.puts "new host #{t[3]}" }
end
Thread.start do
    take_db.each { |_, t| STDERR.puts "host #{t[3]} has disconnected" }
end

STDERR.puts "Started service discovery on #{host}"
begin
    DRb.thread.join
rescue Interrupt
end

DRb.stop_service

