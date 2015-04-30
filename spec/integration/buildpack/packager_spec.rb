require 'spec_helper'
require 'tmpdir'

module Buildpack
  describe Packager do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:buildpack_dir) { File.join(tmp_dir, 'sample-buildpack-root-dir') }
    let(:cache_dir) { File.join(tmp_dir, 'cache-dir') }
    let(:file_location) do
      location = File.join(tmp_dir, 'sample_host')
      File.write(location, 'contents!')
      location
    end
    let(:translated_file_location) { 'file___' + file_location.gsub(/[:\/]/, '_') }

    let(:md5) { Digest::MD5.file(file_location).hexdigest }

    let(:options) {
      {
        root_dir: buildpack_dir,
        mode: buildpack_mode,
        cache_dir: cache_dir,
        manifest_path: manifest_path
      }
    }

    let(:manifest_path) { File.join(buildpack_dir, 'manifest.yml') }
    let(:manifest) {
      {
        exclude_files: files_to_exclude,
        language: 'sample',
        url_to_dependency_map: [{
          match: "ruby-(\d+\.\d+\.\d+)",
          name: "ruby",
          version: "$1",
        }],
        dependencies: [{
          'version' => '1.0',
          'name' => 'etc_host',
          'md5' => md5,
          'uri' => "file://#{file_location}"
        }]
      }
    }

    let(:files_to_include) {
      [
        'VERSION',
        'README.md',
        'lib/sai.to',
        'lib/rash',
      ]
    }

    let(:files_to_exclude) {
      [
        '.gitignore'
      ]
    }

    let(:files) { files_to_include + files_to_exclude }
    let(:cached_file) { File.join(cache_dir, translated_file_location) }

    def create_manifest(manifest)
      File.open(manifest_path, 'w') { |f| f.write manifest.to_yaml }
    end

    before do
      make_fake_files(
        buildpack_dir,
        files
      )
      files_to_include << 'manifest.yml'
      create_manifest(manifest)
      `echo "1.2.3" > #{File.join(buildpack_dir, 'VERSION')}`
    end

    after do
      FileUtils.remove_entry tmp_dir
    end

    describe 'a well formed zip file name' do
      context 'an uncached buildpack' do
        let(:buildpack_mode) { :uncached }

        specify do
          Packager.package(options)

          expect(all_files(buildpack_dir)).to include('sample_buildpack-v1.2.3.zip')
        end
      end

      context 'an cached buildpack' do
        let(:buildpack_mode) { :cached }

        specify do
          Packager.package(options)

          expect(all_files(buildpack_dir)).to include('sample_buildpack-cached-v1.2.3.zip')
        end

      end
    end

    describe 'the zip file contents' do
      context 'an uncached buildpack' do
        let(:buildpack_mode) { :uncached }

        specify do
          Packager.package(options)

          zip_file_path = File.join(buildpack_dir, 'sample_buildpack-v1.2.3.zip')
          zip_contents = get_zip_contents(zip_file_path)

          expect(zip_contents).to match_array(files_to_include)
        end
      end

      context 'a cached buildpack' do
        let(:buildpack_mode) { :cached }

        specify do
          Packager.package(options)


          zip_file_path = File.join(buildpack_dir, 'sample_buildpack-cached-v1.2.3.zip')
          zip_contents = get_zip_contents(zip_file_path)
          dependencies = ["dependencies/#{translated_file_location}"]

          expect(zip_contents).to match_array(files_to_include + dependencies)
        end
      end
    end

    describe 'excluded files' do
      let(:buildpack_mode) { :uncached }

      specify do
        Packager.package(options)

        zip_file_path = File.join(buildpack_dir, 'sample_buildpack-v1.2.3.zip')
        zip_contents = get_zip_contents(zip_file_path)

        expect(zip_contents).to_not include(*files_to_exclude)
      end

      context 'when appending an exclusion for the zip file' do
        specify do
          Packager.package(options)
          create_manifest(manifest.merge(exclude_files: files_to_exclude + ['VERSION']))
          Packager.package(options)

          zip_file_path = File.join(buildpack_dir, 'sample_buildpack-v1.2.3.zip')
          zip_contents = get_zip_contents(zip_file_path)

          expect(zip_contents).to_not include('VERSION')
        end
      end
    end

    describe 'caching of dependencies' do
      context 'an uncached buildpack' do
        let(:buildpack_mode) { :uncached }

        specify do
          Packager.package(options)

          expect(File).to_not exist(cached_file)
        end
      end

      context 'a cached buildpack' do
        let(:buildpack_mode) { :cached }

        context 'by default' do
          specify do
            Packager.package(options)
            expect(File).to exist(cached_file)
          end
        end

        context 'with the force download enabled' do
          context 'and the cached file does not exist' do
            it 'will write the cache file' do
              Packager.package(options.merge(force_download: true))
              expect(File).to exist(cached_file)
            end
          end

          context 'on subsequent calls' do
            it 'does not use the cached file' do
              Packager.package(options.merge(force_download: true))
              File.write(cached_file, 'asdf')
              Packager.package(options.merge(force_download: true))
              expect(File.read(cached_file)).to_not eq 'asdf'
            end
          end
        end

        context 'with the force download disabled' do
          context 'and the cached file does not exist' do
            it 'will write the cache file' do
              Packager.package(options.merge(force_download: false))
              expect(File).to exist(cached_file)
            end
          end

          context 'on subsequent calls' do
            it 'does use the cached file' do
              Packager.package(options.merge(force_download: false))

              expect_any_instance_of(Packager::Package).not_to receive(:download_file)
              Packager.package(options.merge(force_download: false))
            end
          end
        end
      end
    end

    describe 'with a deprecated manifest parameter' do
      let(:deprecated_file_location) do
        location = File.join(tmp_dir, 'sample_deprecated_host')
        File.write(location, 'deprecated contents!')
        location
      end
      let(:deprecated_manifest_path) { File.join(buildpack_dir, '.deprecated.manifest.yml') }
      let(:deprecated_manifest_language) { 'sample' }
      let(:deprecated_manifest) {
        {
          exclude_files: files_to_exclude + ['.DS_Store'],
          language: deprecated_manifest_language,
          url_to_dependency_map: [{
            match: "jruby-(\d+\.\d+\.\d+)",
            name: "jruby",
            version: "$1",
          }],
          dependencies: [{
            'version' => '0.9',
            'name' => 'etc_host',
            'md5' => deprecated_md5,
            'uri' => "file://#{deprecated_file_location}"
          }]
        }
      }
      let(:translated_deprecated_file_location) { 'file___' + deprecated_file_location.gsub(/[:\/]/, '_') }
      let(:deprecated_md5) { Digest::MD5.file(deprecated_file_location).hexdigest }
      let(:zip_file_path) { File.join(buildpack_dir, 'sample_buildpack-cached-v1.2.3.zip') }

      before do
        File.open(deprecated_manifest_path, 'w') { |f| f.write deprecated_manifest.to_yaml }
      end

      it 'generates a new manifest with contents of both the default and deprecated manifests' do
        Packager.package(options.merge({
                                         include_deprecated_manifest: true,
                                         deprecated_manifest_path: deprecated_manifest_path
                                       }))

        manifest_location = File.join(Dir.mktmpdir, 'manifest.yml')

        Zip::File.open(zip_file_path) do |zip_file|
          generated_manifest = zip_file.find { |file| file.name == 'manifest.yml' }
          generated_manifest.extract(manifest_location)
        end

        manifest_contents = YAML.load_file(File.read(manifest_location))

        expect(manifest_contents[:dependencies].count).to eq(2)

        expect(manifest[:dependencies].all? do |dependency|
          manifest_contents[:dependencies].include?(dependency)
        end).to be_true

        expect(deprecated_manifest[:dependencies].all? do |dependency|
          manifest_contents[:dependencies].include?(dependency)
        end).to be_true

        expect(manifest[:url_to_dependency_map].all? do |dependency|
          manifest_contents[:url_to_dependency_map].include?(dependency)
        end).to be_true

        expect(deprecated_manifest[:url_to_dependency_map].all? do |dependency|
          manifest_contents[:url_to_dependency_map].include?(dependency)
        end).to be_true

        expect(manifest[:exclude_files].all? do |dependency|
          manifest_contents[:exclude_files].include?(dependency)
        end).to be_true

        expect(deprecated_manifest[:exclude_files].all? do |dependency|
          manifest_contents[:exclude_files].include?(dependency)
        end).to be_true
      end

      context 'with manifests with mismatched languages' do
        let(:deprecated_manifest_language) { 'wrong_language' }
        it "raises an error" do
          expect do
            Packager.package(options.merge({
              include_deprecated_manifest: true,
              deprecated_manifest_path: deprecated_manifest_path
            }))
          end.to raise_error("Language specified in manifest.yml and .deprecated.manifest.yml do not match.")
        end
      end

      context 'a cached buildpack' do
        let(:buildpack_mode) { :cached }

        it 'zip includes deprecated and current manifest dependencies' do
          Packager.package(options.merge({
            include_deprecated_manifest: true,
            deprecated_manifest_path: deprecated_manifest_path
          }))

          zip_file_path = File.join(buildpack_dir, 'sample_buildpack-cached-v1.2.3.zip')
          zip_contents = get_zip_contents(zip_file_path)

          expect(zip_contents).to include("dependencies/#{translated_file_location}")
          expect(zip_contents).to include("dependencies/#{translated_deprecated_file_location}")
        end
      end
    end

    describe 'when checking checksums' do
      context 'with an invalid MD5' do
        let(:md5) { 'wompwomp' }

        context 'in cached mode' do
          let(:buildpack_mode) { :cached }

          it 'raises an error' do
            expect do
              Packager.package(options)
            end.to raise_error(Packager::CheckSumError)
          end
        end

        context 'in uncached mode' do
          let(:buildpack_mode) { :uncached }

          it 'does not raise an error' do
            expect do
              Packager.package(options)
            end.to_not raise_error
          end
        end
      end
    end

    describe 'existence of zip' do
      let(:buildpack_mode) { :uncached }

      context 'zip is installed' do
        specify do
          expect { Packager.package(options) }.not_to raise_error
        end
      end

      context 'zip is not installed' do
        before do
          allow(Open3).to receive(:capture3).
            with("which zip").
            and_return(['', '', 'exit 1'])
        end

        specify do
          expect { Packager.package(options) }.to raise_error(RuntimeError)
        end
      end
    end

    describe 'avoid changing state of buildpack folder, other than creating the artifact (.zip)' do
      context 'create an cached buildpack' do
        let(:buildpack_mode) { :cached }

        specify 'user does not see dependencies directory in their buildpack folder' do
          Packager.package(options)

          expect(all_files(buildpack_dir)).not_to include("dependencies")
        end
      end
    end
  end
end
