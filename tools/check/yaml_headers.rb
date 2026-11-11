#!/usr/bin/env ruby
# Validate YAML front matter in documents and Pascal source files.
require 'yaml'
require 'date'

root = ENV.fetch('HTTP2_ROOT', File.expand_path('../..', __dir__))
license = 'Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)'
copyright = 'Copyright 2026 Liam Seamus Coughlin'
bad = 0

def check_yaml(path, body, expected_license, expected_copyright)
  errors = []
  begin
    value = YAML.safe_load(body, permitted_classes: [Date], aliases: false)
    errors << 'front matter is not a YAML map' unless value.is_a?(Hash)
    if value.is_a?(Hash)
      errors << 'license value is not the approved SPDX expression' unless value['license'] == expected_license
      errors << 'copyright value is missing or incorrect' unless value['copyright'] == expected_copyright
    end
  rescue Psych::Exception => e
    errors << "invalid YAML: #{e.message.lines.first.to_s.strip}"
  end
  errors.each { |message| puts "FAIL #{path}: #{message}" }
  errors.length
end

docs = Dir[File.join(root, 'doc/**/*.md')].sort
docs.each do |path|
  text = File.read(path)
  unless text.start_with?("---\n")
    puts "FAIL #{path.delete_prefix(root + '/')}: front matter must start on line 1"
    bad += 1
    next
  end
  match = text.match(/\A---\n(.*?)\n---\n/m)
  unless match
    puts "FAIL #{path.delete_prefix(root + '/')}: closing front matter line is missing"
    bad += 1
    next
  end
  lines = match[1].lines
  unless lines[0]&.chomp == "license: #{license}"
    puts "FAIL #{path.delete_prefix(root + '/')}: license must be on line 2"
    bad += 1
  end
  bad += check_yaml(path.delete_prefix(root + '/'), match[1], license, copyright)
end

component_roots = %w[common client server tls/openssl tls/tlslib]
pascal_roots = (%w[test examples tools] + component_roots).map { |d| File.join(root, d) }
pascal_files = pascal_roots.flat_map { |dir| Dir[File.join(dir, '**/*.pas')] }.sort
include_files = component_roots.flat_map { |dir| Dir[File.join(root, dir, '**/*.inc')] }.sort
pascal_files.concat(Dir[File.join(root, '*.pas')])
pascal_files.concat(Dir[File.join(root, 'doc/verification/client-probes/*.pas')])
pascal_files = pascal_files.uniq.sort
(pascal_files + include_files).uniq.sort.each do |path|
  rel = path.delete_prefix(root + '/')
  text = File.read(path)
  match = text.match(/\A\{\*\*\n---\n(.*?)\n---\n\}\n/m)
  unless match
    puts "FAIL #{rel}: pasdoc YAML header must start on line 1 and close without a blank line"
    bad += 1
    next
  end
  lines = match[1].lines
  unless lines[0]&.chomp == "license: #{license}"
    puts "FAIL #{rel}: license must follow the opening front matter line"
    bad += 1
  end
  bad += check_yaml(rel, match[1], license, copyright)
end

puts "Checked #{docs.length} document(s), #{pascal_files.length} Pascal file(s), and #{include_files.length} include file(s); failures=#{bad}"
exit(bad.zero? ? 0 : 1)
