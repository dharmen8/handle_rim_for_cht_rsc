# handle_rim_for_cht_rsc

** Purpose: **
bash script to offload RIM functionality from RSC to a bash script.

** The script's logic is summarized as follows: **
1. Poll the RSC_RIM_QUEUE table and select the 100 oldest records, changing their status from 0 to 1.
2. For the selected records, check if any of them are primary members of a valid F2 SGP.
3. If a primary membership is found, trigger the UNSUB API for that user.
4. If the response status for the UNSUB API is success (0, 302, 303), update the status of the record in RSC_RIM_QUEUE from 1 to 2 (soft-delete).
5. If the response status for the UNSUB API is a failure, trigger the WDAC for secondary members. The response status could be success or failure.
6. For records that have been soft-deleted (status = 2) and have a timestamp older than 30 minutes, invoke the RSC_IMSI_MSISDN_REPLACEMENT stored procedure. The 30-minute delay allows time for the WDAC traces from step #3.3. to be uploaded to the database.
7. As a final step, delete the soft-deleted records that are older than 30 minutes.
 
** NOTE: **
1) I have tested all the steps except for #3.5.
2) Script working folder will be /opt/Roamware/scripts/cron/Retry/RIM.
3) Scripts logs stored at /opt/Roamware/logs/cron/Retry/RIM.
4) Script requires following addition packages to be installed on HOST.
       libxslt-1.1.32-6.el8.x86_64
       xmlstarlet-1.6.1-20.el8.x86_64
       curl-7.61.1-14.el8.x86_64
       libcurl-7.61.1-14.el8.x86_64
