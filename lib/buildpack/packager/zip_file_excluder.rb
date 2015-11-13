module Buildpack
  module Packager
    class ZipFileExcluder
      def generate_exclude_file_list excluded_files
        exclude_list = excluded_files.map do |file|
          if file.chars.last == '/'
            "--exclude=#{file}* --exclude=*/#{file}*"
          else
            "--exclude=#{file} --exclude=*/#{file}"
          end
        end.join(' ')
        exclude_list
      end
    end
  end
end
