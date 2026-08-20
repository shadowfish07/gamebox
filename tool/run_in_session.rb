#!/usr/bin/env ruby
# frozen_string_literal: true

def fail_closed
  exit 125
end

if ARGV.first == "--validate-session"
  ARGV.shift
  exit 2 unless ARGV.length == 2 && ARGV.all? { |value| value.match?(/\A[1-9][0-9]*\z/) }

  process_group = Integer(ARGV[0], 10)
  expected_session = Integer(ARGV[1], 10)
  verified = 0
  begin
    IO.popen(["/bin/ps", "-axo", "pid=,pgid="], "r") do |process_table|
      process_table.each_line do |line|
        fields = line.split
        next unless fields.length == 2 && fields[1].match?(/\A[0-9]+\z/)
        next unless Integer(fields[1], 10) == process_group

        exit 2 unless fields[0].match?(/\A[1-9][0-9]*\z/)
        pid = Integer(fields[0], 10)
        begin
          exit 2 unless Process.getsid(pid) == expected_session
          verified += 1
        rescue Errno::ESRCH
          next
        end
      end
    end
    exit 2 unless $?.success?
  rescue ArgumentError, SystemCallError
    exit 2
  end
  exit(verified.positive? ? 0 : 1)
end

if ARGV.first == "--session-id"
  ARGV.shift
  fail_closed unless ARGV.length == 1 && ARGV.first.match?(/\A[1-9][0-9]*\z/)

  begin
    puts Process.getsid(Integer(ARGV.first, 10))
    exit 0
  rescue ArgumentError, SystemCallError
    fail_closed
  end
end

ready_path = ARGV.shift
separator = ARGV.shift
fail_closed unless ready_path&.start_with?("/") && separator == "--" && !ARGV.empty?

begin
  Process.setsid
  pid = Process.pid
  process_group = Process.getpgrp
  session = Process.getsid(0)
  fail_closed unless pid == process_group && pid == session

  File.open(ready_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |ready|
    ready.write("#{pid} #{process_group} #{session}\n")
    ready.flush
    ready.fsync
  end
  exec(*ARGV)
rescue ArgumentError, SystemCallError
  fail_closed
end
