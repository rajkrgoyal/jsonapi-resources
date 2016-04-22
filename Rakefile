#!/usr/bin/env rake
require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new do |t|
  t.verbose = true
  t.warning = false
  t.test_files = FileList['test/**/*_test.rb']
end

task default: :test

desc 'Run benchmarks'
namespace :test do
  Rake::TestTask.new(:benchmark) do |t|
    t.pattern = 'test/benchmark/*_benchmark.rb'
  end
end
