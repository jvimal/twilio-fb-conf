require 'sinatra'
require 'oauth'
require 'term/ansicolor'
require 'twilio'
require 'ap'
require 'phone'
# Another freshbooks library
require './ruby-freshbooks/lib/ruby-freshbooks'

class TrueClass
  def to_s
    "Yes"
  end
end

class FalseClass
  def to_s
    "No"
  end
end

Phoner::Phone.default_country_code = '1'

Twilio.connect "<sid>", "<secret>"
include Term::ANSIColor

def ph(num)
  Phoner::Phone.parse num
end

CALLER_ID = ph "<insert a valid caller ID here>"
$root = "<insert Twilio Application URL here>"
$conference = {}
$start_time = {}
$error_msgs = {
  nil => "",
  "1" => "You're the only one in your project.  You cannot have a conference call!",
  "2" => "Hours logged for project!",
  "3" => "Project does not have a conference call in progress."
}

enable :sessions

before '/in/*' do
  redirect "/" if session[:site_name] == nil
end

before "/login" do
  redirect "/in/list" if session[:site_name] != nil
end

get "/" do
  erb File.open("index.html").read
end

get '/login' do
  erb File.open("login.html").read
end

post '/login' do
  session[:site_name] = params[:site_name]
  session[:token] = params[:token]
  # Check
  fb = FreshBooks::Client.new session[:site_name], session[:token]
  begin
    fb.project.list
  rescue
    session[:site_name] = nil
    session[:token] = nil
    @msg = "Login failed! :("
    erb File.open("login.html").read
  end
  redirect "/in/list"
end

get '/logout' do
  session[:site_name] = nil
  session[:token] = nil
  redirect "/"
end

get '/in/list' do
  fb = FreshBooks::Client.new(session[:site_name], session[:token])
  projects = fb.project.list["projects"]["project"]
  if projects.class == Hash then
    projects = [projects]
  end
  
  @msg = $error_msgs[params[:m]]
  @session = session
  @projects = []
  @site_name = session[:site_name]
  projects.each { |proj|
    staffs = []
    ss = proj["staff"]
    ss = [proj["staff"]] if proj["staff"].class == Hash
    ss.each { |staff|
      staff = fb.staff.get :staff_id => staff["staff_id"]
      staff = staff["staff"]
      puts "Getting info for staff: #{staff["staff_id"]}".yellow
      staffs << {:name => staff["username"],
                 :email => staff["email"],
                 :mobile => staff["business_phone"]
                }
    }
    @projects << {:name => proj["name"],
                  :id => proj["project_id"],
                  :staffs => staffs.dup}
  }
  
  erb File.open("list.html").read
end

get '/in/conference/:project_id' do
  @session = session
  pid = params[:project_id]
  fb = FreshBooks::Client.new session[:site_name], session[:token]
  project = fb.project.get :project_id => pid
  proj = project["project"]
  # Use twilio to ring all the numbers!
  if proj["staff"].class == Hash
    # Just one member in the project?
    redirect "/in/list?m=1"
  end
  
  @key = "#{session[:token]}:#{pid}"
  @session = session
  $conference[@key] = Array.new
  $start_time[@key] = Time.now

  proj["staff"].each { |staff|
    staff = fb.staff.get :staff_id => staff["staff_id"]
    mobile = staff["business_phone"]
    if  mobile != "" then
      $mobile_to_conf[mobile] = @key
      Twilio::Call.make CALLER_ID, mobile, "#{$root}/voice", :Method => "GET"
    end
  }
  
  erb File.open("list.html").read
end

get '/in/conference_end/:project_id' do
  pid = params[:project_id]
  @session = session
  @key = "#{session[:token]}:#{pid}"
  $conference.delete(@key)
  # Log hours for meeting
  fb = FreshBooks::Client.new session[:site_name], session[:token]
  if $start_time[@key] != nil then
    fb.time_entry.create :time_entry => {:project_id => pid,
                         :task_id => 2, # For meetings
                         :hours => ((Time.now - ($start_time[@key]||Time.now))/3600.0).to_s,
                         :notes => "Conference meeting"}
    redirect "/in/list?m=2"
  else
    redirect "/in/list?m=3"
  end
end

post '/in/page/:project_id' do
  @session = session
  pid = params[:project_id]
  fb = FreshBooks::Client.new session[:site_name], session[:token]
  project = fb.project.get :project_id => pid
  # Use twilio to sms all the numbers!
  if proj["staff"].class == Hash
    # Just one member in the project?
    @msg = "You're the only one in your project!"
    erb File.open("list.html").read
  end
  
  proj["staff"].each { |staff|
    staff = fb.staff.get :staff_id => staff["staff_id"]
    Twilio::Sms.message CALLER_ID, staff["business_phone"], params[:body]
  }
  
  erb File.open("list.html").read
end

get '/voice' do
  caller = ph params[:Caller]
  key = $mobile_to_conf[caller]
  if key == nil
    verb = Twilio::Verb.new { |v|
      v.say "I am sorry, but you are not recognized as a valid caller."
    }
    verb.response
  else
    verb = Twilio::Verb.new { |v|
      v.say "You're now joining the conference."
      v.conference key, :endConferenceOnExit => false
    }
    verb.response
  end
end

post '/voice' do
  caller = ph params[:Caller]
  if params[:CallStatus] == "completed" then
    # TODO! :)
    # Find person by mobile number
    # log the hours of that person
    # Just remove the caller
    $mobile_to_conf.delete(caller)
  end
end
