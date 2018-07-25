require 'base64'

module Fclay
  module Attachment

    extend ActiveSupport::Concern

    CALLBACKS = [:process,:upload,:delete]


    included do

      callbacks = CALLBACKS

      case fclay_options[:without].class.name
        when "Symbol"
          callbacks.clear if fclay_options[:without] == :all
        when "Array"
          callbacks -= fclay_options[:without]
      end

      before_save :process_file if callbacks.include? :process
      after_save :process_upload if callbacks.include? :upload
      before_destroy :delete_files if callbacks.include? :delete

    end

    attr_accessor :file

    def delete_files

      case self.file_location
        when 's3'
          delete_remote_files
        when 'local'
          delete_local_files
      end

    end

    def process_upload
      return unless need_upload
      if self.class.fclay_options[:processing] == :foreground
        upload
      else
        upload_later
      end
    end

    def need_upload
      Fclay.configuration.storage_policy != :local && self.file_location == "local"
    end

    def upload_later

      self.try(:log,"upload_later() called, need_upload: #{need_upload}")
      if need_upload
        job = Fclay::UploadJob.perform_later(self.class.name,self.id)
        self.try(:log,"sheduled! job id: #{job.provider_job_id}")
      end

    end

    def upload
      Fclay::Attachment.upload self.class.name,self.id
    end

    def self.upload type,id
      type = type.safe_constantize
      return unless type
      uploading_object = type.find_by_id(id)
      uploading_object.try(:log,"Fclay::upload() called, uploading_object: #{uploading_object}, uploading_object.need_upload: #{uploading_object.try(:need_upload)}")
      return if !uploading_object || !uploading_object.need_upload
      content_type  = uploading_object.try(:content_type)
      bucket = Fclay.remote_storage.bucket_object

      uploading_object.try(:log,"Start uploading")
      (uploading_object.class.fclay_options[:styles] || [nil]).each do |style|
       obj = bucket.object(uploading_object.remote_file_path(style))
       obj.put({
         body: File.read(uploading_object.local_file_path(style)),
         acl: "public-read",
         content_type: content_type
       })
      end

      type.where(:id => id).update_all(:file_status => 'idle', :file_location => Fclay.remote_storage.name)
      uploading_object.try(:log,"Sucessful uploaded! file_status: 'idle', file_location: #{Fclay.remote_storage.name}")
      uploading_object.delete_local_files
      uploading_object.try(:uploaded)


    end

    def fclay_attachment_presence
     errors.add(:file, 'must be present') if id.blank? && !@file
    end

    def file_size_mb

      "#{((self.file_size >> 10).to_f / 1024).round(2)} Mb" if self.file_size

    end

    def file_url(style=nil)
      return "" unless self.file_location
      case self.file_location
        when "external_link"
          self.file_name
        when "local"
          local_file_url(style)
        else
          remote_file_url(style)
        end
    end

    def final_file_url(style=nil)
      return self.file_name if self.file_location == "external_link"
      if Fclay.configuration.storage_policy != :local
        remote_file_url(style)
      else
        local_file_url(style)
      end
    end

    def remote_file_url(style=nil)
      "https://#{Fclay.remote_storage.bucket_name}.s3.amazonaws.com/#{remote_file_path(style)}"
    end

    def local_file_path(style=nil)

       local_file_dir(style) + "/" + file_name

    end

    def local_file_url(style=nil)
      url = Fclay.configuration.local_storage_host
      url += "#{Fclay.configuration.local_url}/#{self.class.name.tableize}"
      url += "/#{style.to_s}" if style
      url += "/#{file_name}"
      url
    end

    def short_local_file_url(style=nil)

    end

    def local_file_dir(style=nil)
     dir = "#{Rails.root.to_s + Fclay.configuration.local_folder}/#{self.class.name.tableize}"
     dir += "/#{style.to_s}" if style
     dir
    end

    def remote_file_path(style=nil)
      path = ""
      path += "#{self.class.name.tableize}"
      path += "/#{style.to_s}" if style
      path += "/#{file_name}"
      path
    end

    def delete_tmp_file
       FileUtils.rm(@file.try(:path) || @file[:path],{:force => true}) if @file
       @file = nil
    end

    def create_dirs

     (self.class.fclay_options[:styles] || [nil]).each do |style|
       FileUtils.mkdir_p(local_file_dir(style))
     end

    end

    def process_file
      self.try(:log,"process_file called")
      self.try(:log,"@file: #{@file.try(:to_s)}")
      return unless @file

      delete_files
      path = @file.try(:path) || @file.try(:[],:path)

      self.try(:log,"fetched path: #{path.try(:to_s)}")
      return unless path

      self.content_type = @file.try(:content_type) || @file.try(:[],:content_type) if self.respond_to?(:'content_type=')

      if path[0..3] == "http"
        self.file_status = 'idle'
        self.file_location = 'external_link'
        self.file_name = path
      else
        create_dirs
        fetch_file_name

        (self.class.fclay_options[:styles] || [nil]).each do |style|
          FileUtils.cp(path,local_file_path(style))
          `chmod 777 #{local_file_path(style)}`
        end
        self.original_file_name = @file.try(:original_filename) || @file.try(:[],:content_type)
        delete_tmp_file
        set_file_size self.class.fclay_options[:styles].try(:first)
        self.file_location = 'local'
        self.file_status = need_upload ? "processing" : "idle"
        self.try(:log,"file_processed,  file_status: #{self.file_status}")
      end
    end

    def fetch_file_name

      # return if self.file_name.present?
      ext = fetch_extension

      # self.file_name = try(:fclay_attachment_filename)
      self.file_name = SecureRandom.hex #unless self.file_name
      self.file_name += ".#{ext}" if ext

    end

    def fetch_extension
      ext = self.class.fclay_options[:extension]
      return nil if ext == false
      return ext.to_s if ext
      @file.original_filename.split(".").try(:last) if @file.try(:original_filename)
    end

    def delete_local_files

       begin
          (self.class.fclay_options[:styles] || [nil]).each do |style|
            FileUtils.rm(local_file_path(style),{:force => true})
          end
       rescue
          Rails.logger.info "Deleting Media #{id} sync file not found"
       end
       true

    end

    def delete_remote_files

      (self.class.fclay_options[:styles] || [nil]).each do |style|
        Fclay.remote_storage.bucket_object.object(remote_file_path(style)).delete
      end
    end

    def set_file_size style=nil
      self.file_size = File.size local_file_path(style)
    end

    def self.resolve_file_url navigation_complex_id,type,file_name,style=nil

      return "" if file_name.nil? || type.nil?

      path = "http://s3.amazonaws.com/#{Fclay.remote_storage.bucket_name}"
      path += "/navigation_complex/#{navigation_complex_id}" if navigation_complex_id
      path += "/#{type}"
      path += "/#{style.to_s}" if style
      path += "/#{file_name}"
      path
    end

  end
end
