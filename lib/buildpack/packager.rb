require 'buildpack/packager/version'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'kwalify'

module Buildpack
  module Packager
    class CheckSumError < StandardError; end
    class ManifestValidationError < StandardError; end

    def self.package(buildpack)
      package = Package.new(buildpack)
      package.execute!
      package
    end

    class Package < Struct.new(:buildpack)
      def execute!
        validate_manifest
        check_for_zip

        Dir.mktmpdir do |temp_dir|
          copy_buildpack_to_temp_dir(temp_dir)

          if buildpack[:mode] == :offline
            build_dependencies(temp_dir)
            validate_checksums_of_dependencies(temp_dir)
          end

          build_zip_file(zip_file_path, temp_dir)
        end
      end

      private
      def zip_file_path
        File.join(buildpack[:root_dir], zip_file_name)
      end

      def manifest_file_path
        File.join(buildpack[:root_dir], 'manifest.yml')
      end

      def zip_file_name
        "#{buildpack[:language]}_buildpack#{offline_identifier}-v#{buildpack_version}.zip"
      end

      def buildpack_version
        File.read("#{buildpack[:root_dir]}/VERSION").chomp
      end

      def offline_identifier
        return '' unless buildpack[:mode] == :offline
        '-offline'
      end

      def copy_buildpack_to_temp_dir(temp_dir)
        FileUtils.cp_r(File.join(buildpack[:root_dir], '.'), temp_dir)
      end

      def build_zip_file(zip_file_path, temp_dir)
        exclude_files = buildpack[:exclude_files].collect { |e| "--exclude=*#{e}*" }.join(" ")
        `rm -rf #{zip_file_path}`
        `cd #{temp_dir} && zip -r #{zip_file_path} ./ #{exclude_files}`
      end

      def build_dependencies(temp_dir)
        cache_directory = buildpack[:cache_dir] || "#{ENV['HOME']}/.buildpack-packager/cache"
        FileUtils.mkdir_p(cache_directory)

        dependency_dir = File.join(temp_dir, "dependencies")
        FileUtils.mkdir_p(dependency_dir)

        buildpack[:dependencies].each do |dependency|
          translated_filename = dependency['uri'].gsub(/[:\/]/, '_')

          cached_file = File.expand_path(File.join(cache_directory, translated_filename))
          if !buildpack[:cache] || !File.exist?(cached_file)
            download_file(dependency['uri'], cached_file)
          end

          FileUtils.cp(cached_file, dependency_dir)
        end
      end

      def validate_checksums_of_dependencies(temp_dir)
        dependency_dir = File.join(temp_dir, "dependencies")
        buildpack[:dependencies].each do |dependency|
          name = dependency['name']
          version = dependency['version']
          md5 = dependency['md5']
          uri = dependency['uri']

          translated_filename = uri.gsub(/[:\/]/, '_')
          dependency = File.expand_path(File.join(dependency_dir, translated_filename))

          if md5 != Digest::MD5.file(dependency).hexdigest
            raise CheckSumError,
              "File: #{name}, version: #{version} downloaded at location #{uri}\n\tis reporting a different checksum than the one specified in the manifest."
          end
        end
      end

      def check_for_zip
        _, _, status = Open3.capture3("which zip")

        raise RuntimeError, "Zip is not installed\nTry: apt-get install zip\nAnd then rerun" if status.to_s.include?("exit 1")
      end

      def validate_manifest
        validate_manifest_against_schema

        buildpack[:dependencies].each do |dependency|
          uri = dependency['uri']
          if status_code(uri) != 200
            raise ManifestValidationError, "Error while validating manifest: invalid uri: #{uri}"
          end
        end
      end

      def download_file(url, file)
        `curl #{url} -o #{file} -L --fail -f`
      end

      def status_code url
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        if uri.scheme == 'https'
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end

        begin
          status_code = http.head(uri.request_uri).code.to_i
          return status_code unless 404 #if doesn't support head requests

          Net::HTTP.start(uri.host,
                          uri.port,
                          :use_ssl => uri.scheme == 'https'
                         ) do |http|
                           request = Net::HTTP::Get.new uri

                           http.request request do |response|
                             return response.code.to_i
                           end
                         end
        rescue
          false
        end
      end

      def validate_manifest_against_schema
        schema = Kwalify::Yaml.load_file("#{File.dirname(__FILE__)}/packager/schema/manifest_schema.yml")
        validator = Kwalify::Validator.new(schema)
        parser = Kwalify::Yaml::Parser.new(validator)
        parser.parse_file(manifest_file_path)
        unless parser.errors.empty?
          raise ManifestValidationError, "Manifest does not follow proper format:\n#{parser.errors.map{|e| "line=#{e.linenum}, path=#{e.path}, mesg=#{e.message}" }.join("\n")}"
        end
      end

    end
  end
end
