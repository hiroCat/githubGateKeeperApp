require 'sinatra'
require 'octokit'
require 'dotenv/load' # Manages environment variables
require 'json'
require 'openssl'     # Verifies the webhook signature
require 'jwt'         # Authenticates a GitHub App
require 'time'        # Gets ISO 8601 representation of a Time object
require 'logger'      # Logs debug statements

set :port, 3000
set :bind, '0.0.0.0'

class GHAapp < Sinatra::Application
  PRIVATE_KEY = OpenSSL::PKey::RSA.new(ENV['GITHUB_PRIVATE_KEY'].gsub('\n', "\n"))
  WEBHOOK_SECRET = ENV['GITHUB_WEBHOOK_SECRET']
  APP_IDENTIFIER = ENV['GITHUB_APP_IDENTIFIER']
  configure :development do
    set :logging, Logger::DEBUG
  end
  before '/event_handler' do
    get_payload_request(request)
    verify_webhook_signature
    authenticate_app
    authenticate_installation(@payload)
  end

  get '/' do 
    erb :index
  end 

  post '/event_handler' do
    case request.env['HTTP_X_GITHUB_EVENT']
    when 'installation'
      if @payload['action'] === 'created'
        handle_instalation_event
      end
    when 'check_suite'
      if @payload['action'] === 'requested' || @payload['action'] === 'rerequested'
        create_check_run
      end
    when 'check_run'
      logger.debug @payload['check_run']['app']['id'].to_s
      if @payload['check_run']['app']['id'].to_s === APP_IDENTIFIER
        case @payload['action']
        when 'created'
          in_process_check_run(@payload['check_run']['id'])
        when 'rerequested'
          create_check_run
        end
      else
        validate_all_checks
      end
    end

    200 # success status
  end


  helpers do
    def handle_instalation_event
      repos = @payload['repositories']
      logger.debug repos
      repos.each do |r| 
        createBranchProtection r['full_name']
      end      
    end

    def createBranchProtection(element)
      logger.debug element
      @installation_client.put(
        # for the moment we only want this in master , but could be parametrized for other branches 
        "repos/"+element+"/branches/master/protection",
        {
          "required_status_checks": {
            "strict": true,
            "contexts": [
              "continuous-integration/tfs-builds"
            ]
          },
          "enforce_admins": nil,
          "required_pull_request_reviews": nil,
          "restrictions": nil
        }
      )
    end

    def validate_all_checks
      repo = @payload['repository']['full_name']
      sha = @payload['check_run']['head_sha']
      result = @installation_client.check_runs_for_ref(repo, sha)
      cRuns = []
      sRuns = [] 
      d = ''
      logger.debug result.total_count 
      # result.check_runs.select{|e| e.app.id.to_s != APP_IDENTIFIER}.each do |r| 
      result.check_runs.each do |r| 
        logger.debug r.id
        if  r.app.id.to_s != APP_IDENTIFIER
          if r.status == 'completed'
            cRuns << true
          else
            cRuns << false
          end
          if r.conclusion == 'success'
            sRuns << true
          else
            sRuns << false
          end
        else
          d = r.id
        end
      end
      completedAllRuns = cRuns.all?{|n| n == true}
      allRunsOk = sRuns.all?{|n| n == true}
      logger.debug "------------cRuns/sRuns"
      logger.debug cRuns
      logger.debug sRuns
      logger.debug "------------b"
      logger.debug completedAllRuns
      logger.debug allRunsOk
      case 
      when completedAllRuns == true && allRunsOk == true
        end_check_run(d,'success')
      when completedAllRuns == true && allRunsOk == false
        end_check_run(d,'failure')
      else
        in_process_check_run(d)
      end
    end

    def create_check_run
      check_run = @installation_client.post(
        "repos/#{@payload['repository']['full_name']}/check-runs",
        {
          accept: 'application/vnd.github.antiope-preview+json',
          name: 'continuous-integration/tfs-builds',
          head_sha: @payload['check_run'].nil? ? @payload['check_suite']['head_sha'] : @payload['check_run']['head_sha']
        }
      )
    end

    def in_process_check_run(d)
      updated_check_run = @installation_client.patch(
        "repos/#{@payload['repository']['full_name']}/check-runs/" + d.to_s,
        {
          accept: 'application/vnd.github.antiope-preview+json',
          name: 'continuous-integration/tfs-builds',
          status: 'in_progress',
          started_at: Time.now.utc.iso8601
        }
      )
    end

    def end_check_run(d, c)
      updated_check_run = @installation_client.patch(
        "repos/#{@payload['repository']['full_name']}/check-runs/" + d.to_s ,
        {
          accept: 'application/vnd.github.antiope-preview+json',
          name: 'continuous-integration/tfs-builds',
          status: 'completed',
          conclusion: c,
          completed_at: Time.now.utc.iso8601,
        }
      )
    end

    def get_payload_request(request)
      request.body.rewind
      @payload_raw = request.body.read
      begin
        @payload = JSON.parse @payload_raw
      rescue => e
        fail  "Invalid JSON (#{e}): #{@payload_raw}"
      end
    end

    def authenticate_app
      payload = {
          iat: Time.now.to_i,
          exp: Time.now.to_i + (10 * 60),
          iss: APP_IDENTIFIER
      }
      jwt = JWT.encode(payload, PRIVATE_KEY, 'RS256')
      @app_client ||= Octokit::Client.new(bearer_token: jwt)
    end

    def authenticate_installation(payload)
      @installation_id = payload['installation']['id']
      @installation_token = @app_client.create_app_installation_access_token(@installation_id)[:token]
      @installation_client = Octokit::Client.new(bearer_token: @installation_token)
    end

    def verify_webhook_signature
      their_signature_header = request.env['HTTP_X_HUB_SIGNATURE'] || 'sha1='
      method, their_digest = their_signature_header.split('=')
      our_digest = OpenSSL::HMAC.hexdigest(method, WEBHOOK_SECRET, @payload_raw)
      halt 401 unless their_digest == our_digest
      logger.debug "---- received event #{request.env['HTTP_X_GITHUB_EVENT']}"
      logger.debug "----    action #{@payload['action']}" unless @payload['action'].nil?
    end

  end

  run! if __FILE__ == $0
end
