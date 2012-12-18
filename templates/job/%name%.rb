# :first_in sets how long it takes before the job is first run. In this case, it is run immediately
Dashing::SCHEDULER.every '1m', :first_in => 0 do |job|
  Dashing::Application.send_event('widget_id', { })
end