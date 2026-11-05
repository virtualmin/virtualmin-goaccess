#### Version 1.0.1
* Add GoAccess reports for Apache and Nginx websites as a Virtualmin feature
* Add hourly, daily or manual report updates
* Add settings for log format, days to include, entries per panel, rotated logs, anonymized IPs, query strings and crawlers
* Add HTML report downloads
* Add a report list with each domain's schedule, last update, requests and status
* Add domain owner access with permissions for updating reports and changing settings
* Add module config options for the GoAccess path, time limit, log file limit and default schedule
* Add report generation as the domain owner with a time limit, keeping the last good report if an update fails
* Add report backup and restore, paused updates while a server is disabled, and cleanup when the feature is removed
* Add report checks to Validate Virtual Servers, covering the GoAccess install, settings and scheduled job
* Add Webmin Actions Log entries for report updates and settings changes
