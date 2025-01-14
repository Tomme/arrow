# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

require "English"
require "open-uri"
require "time"

class PackageTask
  include Rake::DSL

  def initialize(package, version, release_time, options={})
    @package = package
    @version = version
    @release_time = release_time

    @archive_base_name = "#{@package}-#{@version}"
    @archive_name = "#{@archive_base_name}.tar.gz"
    @full_archive_name = File.expand_path(@archive_name)

    @rpm_package = @package
    case @version
    when /-((dev|rc)\d+)\z/
      base_version = $PREMATCH
      sub_version = $1
      type = $2
      if type == "rc" and options[:rc_build_type] == :release
        @deb_upstream_version = base_version
        @rpm_version = base_version
        @rpm_release = "1"
      else
        @deb_upstream_version = "#{base_version}~#{sub_version}"
        @rpm_version = base_version
        @rpm_release = "0.#{sub_version}"
      end
    else
      @deb_upstream_version = @version
      @rpm_version = @version
      @rpm_release = "1"
    end
    @deb_release = "1"
  end

  def define
    define_dist_task
    define_yum_task
    define_apt_task
    define_version_task
  end

  private
  def env_value(name)
    value = ENV[name]
    raise "Specify #{name} environment variable" if value.nil?
    value
  end

  def parallel_build?
    ENV["PARALLEL"] == "yes"
  end

  def debug_build?
    ENV["DEBUG"] != "no"
  end

  def git_directory?(directory)
    candidate_paths = [".git", "HEAD"]
    candidate_paths.any? do |candidate_path|
      File.exist?(File.join(directory, candidate_path))
    end
  end

  def latest_commit_time(git_directory)
    return nil unless git_directory?(git_directory)
    cd(git_directory) do
      return Time.iso8601(`git log -n 1 --format=%aI`.chomp).utc
    end
  end

  def download(url, output_path)
    if File.directory?(output_path)
      base_name = url.split("/").last
      output_path = File.join(output_path, base_name)
    end
    absolute_output_path = File.expand_path(output_path)

    unless File.exist?(absolute_output_path)
      mkdir_p(File.dirname(absolute_output_path))
      rake_output_message "Downloading... #{url}"
      open(url) do |downloaded_file|
        File.open(absolute_output_path, "wb") do |output_file|
          output_file.print(downloaded_file.read)
        end
      end
    end

    absolute_output_path
  end

  def run_docker(id)
    docker_tag = "#{@package}-#{id}"
    build_command_line = [
      "docker",
      "build",
      "--tag", docker_tag,
    ]
    run_command_line = [
      "docker",
      "run",
      "--rm",
      "--tty",
      "--volume", "#{Dir.pwd}:/host:rw",
    ]
    if debug_build?
      build_command_line.concat(["--build-arg", "DEBUG=yes"])
      run_command_line.concat(["--env", "DEBUG=yes"])
    end
    build_command_line << id
    run_command_line.concat([docker_tag, "/host/build.sh"])

    sh(*build_command_line)
    sh(*run_command_line)
  end

  def define_dist_task
    define_archive_task
    desc "Create release package"
    task :dist => [@archive_name]
  end

  def define_yum_task
    namespace :yum do
      distribution = "centos"
      yum_dir = "yum"
      repositories_dir = "#{yum_dir}/repositories"

      directory repositories_dir

      desc "Build RPM packages"
      task :build => [@archive_name, repositories_dir] do
        tmp_dir = "#{yum_dir}/tmp"
        rm_rf(tmp_dir)
        mkdir_p(tmp_dir)
        rpm_archive_name = "#{@package}-#{@rpm_version}.tar.gz"
        cp(@archive_name,
           File.join(tmp_dir, rpm_archive_name))

        env_sh = "#{yum_dir}/env.sh"
        File.open(env_sh, "w") do |file|
          file.puts(<<-ENV)
SOURCE_ARCHIVE=#{rpm_archive_name}
PACKAGE=#{@rpm_package}
VERSION=#{@rpm_version}
RELEASE=#{@rpm_release}
          ENV
        end

        tmp_distribution_dir = "#{tmp_dir}/#{distribution}"
        mkdir_p(tmp_distribution_dir)
        spec = "#{tmp_distribution_dir}/#{@rpm_package}.spec"
        spec_in = "#{yum_dir}/#{@rpm_package}.spec.in"
        spec_in_data = File.read(spec_in)
        spec_data = spec_in_data.gsub(/@(.+?)@/) do |matched|
          case $1
          when "PACKAGE"
            @rpm_package
          when "VERSION"
            @rpm_version
          when "RELEASE"
            @rpm_release
          else
            matched
          end
        end
        File.open(spec, "w") do |spec_file|
          spec_file.print(spec_data)
        end

        cd(yum_dir) do
          distribution_versions = (ENV["CENTOS_VERSIONS"] || "6,7").split(",")
          threads = []
          distribution_versions.each do |version|
            id = "#{distribution}-#{version}"
            if parallel_build?
              threads << Thread.new(id) do |local_id|
                run_docker(local_id)
              end
            else
              run_docker(id)
            end
          end
          threads.each(&:join)
        end
      end
    end

    desc "Release Yum packages"
    yum_tasks = [
      "yum:build",
    ]
    task :yum => yum_tasks
  end

  def define_apt_task
    namespace :apt do
      apt_dir = "apt"
      repositories_dir = "#{apt_dir}/repositories"

      directory repositories_dir

      desc "Build deb packages"
      task :build => [@archive_name, repositories_dir] do
        tmp_dir = "#{apt_dir}/tmp"
        rm_rf(tmp_dir)
        mkdir_p(tmp_dir)
        deb_archive_name = "#{@package}-#{@deb_upstream_version}.tar.gz"
        cp(@archive_name,
           File.join(tmp_dir, deb_archive_name))
        Dir.glob("debian*") do |debian_dir|
          cp_r(debian_dir, "#{tmp_dir}/#{debian_dir}")
        end

        env_sh = "#{apt_dir}/env.sh"
        File.open(env_sh, "w") do |file|
          file.puts(<<-ENV)
PACKAGE=#{@package}
VERSION=#{@deb_upstream_version}
          ENV
        end

        cd(apt_dir) do
          threads = []
          targets = (ENV["APT_TARGETS"] || "").split(",")
          if targets.empty?
            targets = [
              "debian-stretch",
              # Disable by default for now because it requires some setups on host.
              # "debian-stretch-arm64",
              "ubuntu-xenial",
              "ubuntu-bionic",
              "ubuntu-cosmic",
            ]
          end
          targets.each do |target|
            next unless Dir.exist?(target)
            id = target
            if parallel_build?
              threads << Thread.new(id) do |local_id|
                run_docker(local_id)
              end
            else
              run_docker(id)
            end
          end
          threads.each(&:join)
        end
      end
    end

    desc "Release APT repositories"
    apt_tasks = [
      "apt:build",
    ]
    task :apt => apt_tasks
  end

  def define_version_task
    namespace :version do
      desc "Update versions"
      task :update do
        update_debian_changelog
        update_spec
      end
    end
  end

  def package_changelog_message
    "New upstream release."
  end

  def packager_name
    ENV["DEBFULLNAME"] || ENV["NAME"] || `git config --get user.name`.chomp
  end

  def packager_email
    ENV["DEBEMAIL"] || ENV["EMAIL"] || `git config --get user.email`.chomp
  end

  def update_content(path)
    if File.exist?(path)
      content = File.read(path)
    else
      content = ""
    end
    content = yield(content)
    File.open(path, "w") do |file|
      file.puts(content)
    end
  end

  def update_debian_changelog
    Dir.glob("debian*") do |debian_dir|
      update_content("#{debian_dir}/changelog") do |content|
        <<-CHANGELOG.rstrip
#{@package} (#{@deb_upstream_version}-#{@deb_release}) unstable; urgency=low

  * New upstream release.

 -- #{packager_name} <#{packager_email}>  #{@release_time.rfc2822}

#{content}
        CHANGELOG
      end
    end
  end

  def update_spec
    release_time = @release_time.strftime("%a %b %d %Y")
    update_content("yum/#{@rpm_package}.spec.in") do |content|
      content = content.sub(/^(%changelog\n)/, <<-CHANGELOG)
%changelog
* #{release_time} #{packager_name} <#{packager_email}> - #{@rpm_version}-#{@rpm_release}
- #{package_changelog_message}

      CHANGELOG
      content = content.sub(/^(Release:\s+)\d+/, "\\11")
      content.rstrip
    end
  end

end
