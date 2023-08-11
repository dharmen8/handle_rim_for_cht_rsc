#!/bin/bash
##########################################################################################
#
#   InterASIA Solutions Inc. 2012
#
#   Program: trigger_rim_api.sh
#
#   CopyRight to Dharmen Panchal (dharmen_panchal@int-asia.com.tw).
#
#   History
#   ------------------------------------------------------------------------------------
#   v1        2023/07/25      Dharmen Panchal     Created
#   v2        2023/08/09      Dharmen Panchal     RIM delayed to WDAC related trace upload to DB.
#
##########################################################################################

# Load environment variables and functions
. /opt/Roamware/scripts/setup.sh

# Initialize variables
DEBUG_LOG=1
_script_dir="/opt/Roamware/scripts/Retry/RIM"
_os=$(/usr/bin/uname)
_hostname=$(hostname | sed -e "s/\..*//")
_progname=$(basename "$0" .sh)
_user=$(/bin/whoami)
log_file="/opt/Roamware/logs/cron/Retry/RIM/${_progname}.log"
timestamp=$(date +%Y%m%d%H%M%S)
roamconfig_ini="/opt/Roamware/scripts/operations/RoamConfig.ini"
db_sid=$(awk -F'=' '{if ($1 == "oracle.sid" ) print $2}' $roamconfig_ini)
db_user=$(awk -F'=' '{if ($1 == "oracle.user" ) print $2}' $roamconfig_ini)
db_passwd=$(awk -F'=' '{if ($1 == "oracle.passwd" ) print $2}' $roamconfig_ini)

# Set API URLs
api_p_url="http://192.168.124.44:8888/ProvReq?TxnId=123456789013&ReqType=PROVSGRP&Action=UNSUB&Version=2&CSR=227,030001&Channel=CAS&RatePlanName=&SecondaryIMSI=&SecondaryMSISDN=&RatePlanId={packageid}&PrimaryMSISDN={p_msisdn}&PrimaryIMSI={p_imsi}&Timestamp={timestamp}&RatePlanStartDate={acttime}"
api_s_url="http://192.168.124.44:8888/ProvReq?TxnId=123456789013&ReqType=PROVSGRP&Action=UNSUB&Version=2&CSR=227,030001&Channel=CAS&RatePlanName=&Timestamp={timestamp}&RatePlanId={packageid}&PrimaryMSISDN={p_msisdn}&PrimaryIMSI={p_imsi}&SecondaryMSISDN={s_msisdn}&SecondaryIMSI={s_imsi}&RatePlanStartDate={acttime}"


##########################################################################################
#
#   Function    : validate_numeric_input
#   Purpose     : Validate msisdn format
#   arg         : None
#   return      : 0 for valid; others for fail
#
##########################################################################################
validate_numeric_input() {
    local num=$1
    [[ $num =~ ^[0-9]+$ ]]
}


##########################################################################################
#
#   Function    : fetch_records
#   Purpose     : Fetch records from the database
#   arg         : sql query
#   return      : query result
#
##########################################################################################
fetch_records() {
    local query="$1"
    local req_output
    req_output=$("$ORACLE_HOME/bin/sqlplus" -s "$db_user/$db_passwd@$db_sid" <<EOF
        set heading off feedback off verify off lines 200 ;
        alter session set nls_timestamp_format = 'yyyymmddhh24miss' ;
        alter session set nls_date_format = 'yyyymmddhh24miss' ;
        $query
        quit ;
EOF
    )
    # Remove "Session altered" and empty lines from the output
    req_output=$(echo "$req_output" | awk '!/Session altered/ && NF')
    echo "$req_output"
}


##########################################################################################
#
#   Function    : convert_to_rateplan_id
#   Purpose     : Convert number to RatePlan ID format
#   arg         : Rate Plan Id in numberic format
#   return      : Rate Plan Id in CHT format
#
##########################################################################################
convert_to_rateplan_id() {
    printf "RX%07d" "$1"
}


##########################################################################################
#
#   Function    : add_leading_zero
#   Purpose     : Add leading zero to MSISDN
#   arg         : MSISDN in E.164
#   return      : MSISDN in API format.
#
##########################################################################################
add_leading_zero() {
    local msisdn=$1
    echo "0${msisdn#886}"
}


##########################################################################################
#
#   Function    : log
#   arg1        : -d write down date info
#   arg2        : -n w/o new line
#   arg3        : message to log down
#   return      : None
#
##########################################################################################

log() {
    if [ "$1" = "-d" ]; then
        shift
        _date_str=$(date '+%Y %b %d %H:%M:%S')
        _msg=$(printf "%s %s %s: " "$_date_str" "${_hostname}" "${_progname}[$$]")
    else
        _msg=""
    fi

    if [ "$1" = "-n" ]; then
        shift
        if [ "$DEBUG_LOG" -eq 1 ]; then
            printf "%s%s" "$_msg" "$1" | tee -a "${log_file}"
        else
            printf "%s%s" "$_msg" "$1"
        fi
    else
        if [ "$DEBUG_LOG" -eq 1 ]; then
            printf "%s%s\n" "$_msg" "$1" | tee -a "${log_file}"
        else
            printf "%s%s\n" "$_msg" "$1"
        fi
    fi
    breath_cnt=0
    return 0
}


##########################################################################################
#
#   Function    : trigger_api
#   Purpose     : Trigger API and handle response
#   arg         : api request url
#   return      : api response status
#
##########################################################################################
trigger_api() {
    local url=$1
    local xml_output
    local status
    xml_output=$(curl -s "$url")
    status=$(echo "<dummy>$xml_output</dummy>" | xmlstarlet sel -t -v "//Status" 2>/dev/null)
    echo "$status"
}


##########################################################################################
#
#   Function    : call_rim_sp
#   Purpose     : Call RIM Store Procedure
#   arg         : MSISDN in E.164
#   return      : DB Uppdate status
#
##########################################################################################
call_rim_sp() {
    local command=5
    local oldmsisdn="$1"
    local sql_script

    if ! validate_numeric_input "$oldmsisdn"; then
        log -d "Skipping record due to invalid oldmsisdn: $oldmsisdn"
        return 1
    fi

    # Create SQL script
    sql_script=$(cat <<EOF
    set serveroutput on ;
    DECLARE
        COMMAND NUMBER;
        OLDIMSI VARCHAR2(200);
        NEWIMSI VARCHAR2(200);
        OLDMSISDN VARCHAR2(200);
        NEWMSISDN VARCHAR2(200);
        STATUS NUMBER;
        RESPONSE VARCHAR2(200);
        OUT_MESSAGE VARCHAR2(200);
    BEGIN
        COMMAND := $command ;
        OLDIMSI := NULL ;
        NEWIMSI := NULL ;
        OLDMSISDN := '$oldmsisdn' ;
        NEWMSISDN := NULL ;
        RSC_IMSI_MSISDN_REPLACEMENT(
            COMMAND => COMMAND,
            OLDIMSI => OLDIMSI,
            NEWIMSI => NEWIMSI,
            OLDMSISDN => OLDMSISDN,
            NEWMSISDN => NEWMSISDN,
            STATUS => STATUS,
            RESPONSE => RESPONSE,
            OUT_MESSAGE => OUT_MESSAGE
        );
        DBMS_OUTPUT.PUT_LINE('status=' || STATUS);
        DBMS_OUTPUT.PUT_LINE('response=' || RESPONSE);
        DBMS_OUTPUT.PUT_LINE('out_message=' || OUT_MESSAGE);
    END;
    /
EOF
    )

    # Call SQLPlus and capture output
    sqlplus_output=$(sqlplus -s "$db_user/$db_passwd@$db_sid" <<EOF
        $sql_script
EOF
    )

    # Extract output values
    local status=$(echo "$sqlplus_output" | awk -F'=' '/status/ {print $2}')
    echo "$status"
}


##########################################################################################
#
#   Function    : check_for_rim_records
#   Purpose     : Function Fetch RIM records
#   arg         : None
#   return      : RIM MSISDN list when there are records, 1 when none.
#   note        : Cannot give log statement as it will be returned into calling function.
#
##########################################################################################
check_for_rim_records(){

    # rsc_rim_queue {
    #     rrq_msisdn     varchar2(20),
    #     rrq_timestamp  date,
    #     rrq_rec_status number(1) default 0
    # } tablespace RSCConfigTS ;

    local sql_command="UPDATE rsc_rim_queue SET rrq_rec_status = 1
    WHERE ROWID IN (
        SELECT rid
        FROM (
            SELECT ROWID AS rid
            FROM rsc_rim_queue 
            WHERE rrq_rec_status = 0
            ORDER BY rrq_timestamp
        )
        WHERE ROWNUM <= 100
    );"

    # Execute the SQL command and capture the number of records affected
    num_records_updated=$(sqlplus -s "$db_user/$db_passwd@$db_sid" <<EOF
        set heading off verify off lines 200 ;
        $sql_command
        commit;
        quit;
EOF
        )

    # Check if any records were updated
    local total_records_updated=$(echo "$num_records_updated" | grep -o '[0-9]\+ row[s]* updated' | awk '{ sum += $1 } END { print sum }')
    total_records_updated=${total_records_updated:-0}

    # total records to be RIM
    sql_command="select count(1) from rsc_rim_queue where rrq_rec_status=2 and rrq_timestamp < sysdate - 1/48 ;"
    local num_records=$(sqlplus -s "$db_user/$db_passwd@$db_sid" <<EOF
        set heading off verify off lines 200 ;
        $sql_command
        quit;
EOF
        )

    num_records=$(echo "$num_records" | awk '!/Session altered/ && NF')
    num_records=${num_records:-0}
    local total_records=$((num_records+total_records_updated))
    total_records=${total_records:-0}

    # return total record cound
    echo "$total_records"
    
}


##########################################################################################
#
#   Function    : soft_delete_rim_queue
#   Purpose     : 
#   arg         : MSISDN (E.164)
#   return      : None
#
##########################################################################################
soft_delete_rim_queue() {
    
    # check if msisdn is in numberic format
    if ! validate_numeric_input "$1"; then
        log -d "Skipping record due to invalid msisdn: $1"
        return 1
    fi


    # soft delete records
    local sql_command="update rsc_rim_queue set rrq_rec_status=2,rrq_timestamp=sysdate where rrq_msisdn='$1' ;"

    local num_records_updated=$(sqlplus -s "$db_user/$db_passwd@$db_sid" <<EOF
        set heading off verify off lines 200 ;
        $sql_command
        commit;
        quit;
EOF
        )

    # check how many records got updated
    local total_records_updated=$(echo "$num_records_updated" | grep -o '[0-9]\+ row[s]* updated' | awk '{ sum += $1 } END { print sum }')
    total_records_updated=${total_records_updated:-0}
    
    if [ $total_records_updated -gt 0 ]; then 
        log -d "$1 soft deleted successfully from rsc_req_queue."
    else 
        log -d "$1 soft deleted failed from rsc_req_queue."
    fi
}


##########################################################################################
#
#   Function    : delete_rim_queue
#   Purpose     : delete processed records from rsc_rim_queue
#   arg         : MSISDN in E.164
#   return      : none
#
##########################################################################################
delete_rim_queue() {
    local sql_command="delete from rsc_rim_queue where rrq_rec_status = 2 and rrq_timestamp < sysdate - 1/48 ; "
    local num_records_deleted=$(sqlplus -s "$db_user/$db_passwd@$db_sid" <<EOF
        set heading off verify off lines 200 ;
        $sql_command
        commit;
        quit;
EOF
    )
    local total_records_deleted=$(echo "$num_records_deleted" | grep -o '[0-9]\+ row[s]* deleted' | awk '{ sum += $1 } END { print sum }')
    total_records_deleted=${total_records_deleted:-0}
    log -d "Deleted $total_records_deleted records from rsc_req_queue."
}


##########################################################################################
#
#   Function    : wdac_secondary_members
#   Purpose     : Function to handle Primary members WDAC failure and trigger wdac for secondary.
#   arg         : Primary MSISDN (E.164), Primary IMSI
#   return      : DB Uppdate status
#
##########################################################################################
wdac_secondary_members() {
    # variable 
    local secondary_member
    local values
    local rsgc_primary=$1 
    local rsgc_primary_imsi=$2

    # Get secondary member details for wdac from primary member
    secondary_members_list=$(fetch_records "
    SELECT rsgc.rsgc_secondary || ' ' || rsgc.rsgc_secondary_imsi || ' ' || rrm.rrm_rate_plan_id || ' ' || srs.srs_rate_plan_start
    FROM rsc_shared_group_config rsgc 
    JOIN rsc_subr_rateplan_store srs ON rsgc_primary = srs_msisdn AND rsgc_order_id = srs_order_id
    JOIN rsc_rateplan_master rrm ON srs_rate_plan = rrm_rate_plan_name
    WHERE rsgc_primary = '$p_msisdn'
    AND rsgc_end_date > SYSDATE
    AND rsgc_status    <> 2
    AND srs_rec_status <> 2
    AND rrm_rec_status <> 2 ;
    ")

    # Loop through secondary members list
    if [ -n "$secondary_members_list" ]; then
        # The while loop reads each line from the secondary_members_list and splits it into individual values using the space delimiter. 
        while IFS= read -r secondary_member; do
            # splits $secondary_member into individual $values using the space delimiter
            IFS=' ' read -ra values <<< "$secondary_member"
    
            # initialize url.
            set_api_url
    
            # Convert msisdn to cht API format.
            local rsgc_secondary=$(add_leading_zero "${values[0]}")
            local rsgc_secondary_imsi="${values[1]}"
            local rrm_rate_plan_id="${values[2]}"
            local srs_rate_plan_start="${values[3]}"

            # Validate RP-ID before using them
            if validate_numeric_input "$rrm_rate_plan_id"; then
                # Convert to CHT format
                rrm_rate_plan_id=$(convert_to_rateplan_id "$rrm_rate_plan_id")
            else
                log -d "Skipping record due to invalid rate plan ID: $rrm_rate_plan_id"
                continue
            fi

            log -d "Original MSISDN("${values[0]}"), Modified MSISDN ($rsgc_secondary)"
            log -d "Original RPID("${values[2]}"), Modified RPID ($rrm_rate_plan_id)"
    
            # placeholder substitution in api-url.
            api_s_url=${api_s_url//\{p_msisdn\}/$rsgc_primary}
            api_s_url=${api_s_url//\{p_imsi\}/$rsgc_primary_imsi}
            api_s_url=${api_s_url//\{s_msisdn\}/$rsgc_secondary}
            api_s_url=${api_s_url//\{s_imsi\}/$rsgc_secondary_imsi}
            api_s_url=${api_s_url//\{packageid\}/$rrm_rate_plan_id}
            api_s_url=${api_s_url//\{timestamp\}/$timestamp}
            api_s_url=${api_s_url//\{acttime\}/$srs_rate_plan_start}
    
            # Trigger API 
            log -d "Triggering API : $api_s_url"
            status=$(trigger_api "$api_s_url")

            # print status    
            echo "WDAC [${values[0]}], Status [$status]"
        done <<< "$secondary_members_list"
    fi
}


##########################################################################################
#
#   Function    : process_primary_members
#   Purpose     : Process F2 SGP primary members.
#   arg         : Primary MSISDN (E.164), Primary IMSI
#   return      : DB Uppdate status
#
##########################################################################################
process_primary_members() {
    local primary_members_list="$1"

    # the "primary_members_list" is split into an array called "primary_member" array, and each element of the "primary_member" is then split into individual values using the space delimiter. 
    # This allows you to access and assign the values for rrq_msisdn, srs_imsi, rrm_rate_plan_id, and srs_rate_plan_start from the "values" array.    
    while IFS= read -r primary_member; do
        IFS=' ' read -ra values <<< "$primary_member"

        local rrq_msisdn=$(add_leading_zero "${values[0]}")
        local srs_imsi="${values[1]}"
        local rrm_rate_plan_id="${values[2]}"
        local srs_rate_plan_start="${values[3]}"

        if validate_numeric_input "$rrm_rate_plan_id"; then
            rrm_rate_plan_id=$(convert_to_rateplan_id "$rrm_rate_plan_id")
        else
            log -d "Skipping record due to invalid rate plan ID: $rrm_rate_plan_id"
            continue
        fi

        log -d "Original MSISDN(${values[0]}), Modified MSISDN ($rrq_msisdn)"
        log -d "Original RPID(${values[2]}), Modified RPID ($rrm_rate_plan_id)"

        # Substitution of placeholders in the API URL
        local api_p_url_substituted="$api_p_url"
        api_p_url_substituted=${api_p_url_substituted//\{p_msisdn\}/$rrq_msisdn}
        api_p_url_substituted=${api_p_url_substituted//\{p_imsi\}/$srs_imsi}
        api_p_url_substituted=${api_p_url_substituted//\{packageid\}/$rrm_rate_plan_id}
        api_p_url_substituted=${api_p_url_substituted//\{timestamp\}/$timestamp}
        api_p_url_substituted=${api_p_url_substituted//\{acttime\}/$srs_rate_plan_start}

        log -d "Triggering API : $api_p_url_substituted"
        status=$(trigger_api "$api_p_url_substituted")

        case "$status" in
            0|302|303)
                log -d "WDAC [${values[0]}], Status [$status]."
                log -d "Executing soft-delete for ${values[0]}"
                soft_delete_rim_queue "${values[0]}"
                ;;
            *)
                log -d "WDAC [${values[0]}] failed with Status [$status]."
                log -d "Executing wdac_secondary_members for ${values[0]}"
                wdac_secondary_members "${values[0]}" "$srs_imsi"
                ;;
        esac
        
    done <<< "$primary_members_list"
}


##########################################################################################
#
#   Function    : process_non_primary_members
#   Purpose     : Process non-F2 SGP primary members.
#   arg         : Primary MSISDN (E.164), Primary IMSI
#   return      : DB Uppdate status
#
##########################################################################################
process_non_primary_members() {
    local non_primary_members_list="$1"

    while IFS= read -r r_msisdn; do
        log -d "Executing soft-delete for $r_msisdn"
        soft_delete_rim_queue "$r_msisdn"
    done <<< "$non_primary_members_list"
}


##########################################################################################
#
#   Function    : process_rim_users
#   Purpose     : Process RIM users list.
#   arg         : Primary MSISDN (E.164), Primary IMSI
#   return      : DB Uppdate status
#
##########################################################################################
process_rim_users() {
    local rim_users_list="$1"

    while IFS= read -r r_msisdn; do
        log -d "Executing call_rim_sp for $r_msisdn"
        rim_status=$(call_rim_sp "$r_msisdn")
        rim_status=${rim_status:-1}
        if [ "$rim_status" -eq 0 ]; then
            log -d "RIM done successfully, executing delete_rim_queue($r_msisdn)"
        fi
    done <<< "$rim_users_list"

    log -d "Executing delete_rim_queue..."
    delete_rim_queue
    log -d "Finished executing delete_rim_queue."
}


##########################################################################################
#
#   Function    : main
#   Purpose     : 
#   arg         : None
#   return      : None
#
##########################################################################################
main() {
    #---- Start by checking if any RIM records for processing. 
    log -d "Executing check_for_rim_records."
    rec_count=$(check_for_rim_records)
    rec_count=${rec_count:-0}
    log -d "Total records to process: $rec_count"
    log -d "Finished executing check_for_rim_records."

    # Exit if rec_count is 0, remove any newline or whitespace before the check.
    if [[ "$rec_count" -eq 0 || -z "$(echo "$rec_count" | tr -d '[:space:]')" ]]; then
        log -d "No records for RIM. Exiting..."
        exit
    fi

    #---- Handling for primary member.
    # Handling for RIM user as primary member with active subscription. Load all such users.
    log -d "Executing check for primary_members_list."
    primary_members_list=$(fetch_records "SELECT distinct rrq_msisdn || ' ' || srs_imsi || ' ' || rrm_rate_plan_id || ' ' || srs_rate_plan_start
        FROM rsc_rim_queue rrq
        JOIN rsc_shared_group_config rsgc ON rsgc_primary = rrq_msisdn
        JOIN rsc_subr_rateplan_store srs ON rsgc_primary = srs_msisdn AND rsgc_order_id = srs_order_id
        JOIN rsc_rateplan_master rrm ON srs_rate_plan = rrm_rate_plan_name
        WHERE rrq_rec_status = '1'
        AND rsgc_end_date > SYSDATE
        AND rsgc_status    <> 2
        AND srs_rec_status <> 2
        AND rrm_rec_status <> 2 ;")
    
    log -d "primary_members_list: $( [ -n "$primary_members_list" ] && echo "$primary_members_list" | tr '\n' ' ' || echo 0 )"

    if [ -n "$primary_members_list" ]; then
        process_primary_members "$primary_members_list"
    fi
    log -d "Finished processing primary_members_list."

    #---- Handling for rest of the users.
    log -d "Executing check for non_primary_members_list."
    non_primary_members_list=$(fetch_records "SELECT distinct rrq_msisdn 
        FROM rsc_rim_queue rrq
        WHERE rrq_rec_status = '1' 
        AND not exists ( 
            select 1 from rsc_shared_group_config where rsgc_primary = rrq_msisdn and rsgc_status <> 2 and rsgc_end_date > sysdate );")
    
    log -d "non_primary_members_list: $( [ -n "$non_primary_members_list" ] && echo "$non_primary_members_list" | tr '\n' ' ' || echo 0 )"
    
    if [ -n "$non_primary_members_list" ]; then
        process_non_primary_members "$non_primary_members_list"
    fi
    log -d "Finished processing non_primary_members_list."

    #---- Executing RIM
    log -d "Executing check for rim_users_list."
    rim_users_list=$(fetch_records "SELECT distinct rrq_msisdn 
        FROM rsc_rim_queue rrq
        WHERE rrq_rec_status = '2' 
        AND rrq_timestamp < sysdate - 1/48 ;")
    
    log -d "rim_users_list: $( [ -n "$rim_users_list" ] && echo "$rim_users_list" | tr '\n' ' ' || echo 0 )"
    
    if [ -n "$rim_users_list" ]; then
        process_rim_users "$rim_users_list"
    fi
    log -d "Finished processing rim_users_list."
    log -d "Finished processing. Exiting..."
}




#---------------------------------- Start the main program
main
