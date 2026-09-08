##########################################################################################################################################################
#
#TESTSIGMA_API_KEY-->API key generated under Testsigma App-->Configuration-->API Keys
#TESTSIGMA_TEST_PLAN_ID--> Testsigma Testplan ID, U can get this ID from Testsigma_app-->Test Plans--><TEST_PLAN_NAME>-->CI/CD Integration
#MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT-->Maximum time the script will wait for TEST Plan execution to complete.
#REPORT_FILE_PATH-->File path to save report Ex: <DIR_PATH>/report.xml, ./report.xml
#
#ADO_ORG / ADO_PROJECT --> Your Azure DevOps organization and project name
#ADO_PLAN_ID --> The ONLY Azure DevOps id you configure. Find it by opening the
#                Test Plan and reading the number in the URL: .../_testPlans/execute?planId=XXXX
#ADO_PAT --> Auth token for Azure DevOps API
#
# NOTHING ELSE IS HARDCODED. For every test result:
#   1. WIQL query resolves the ADO Test Case work item whose Automated Test Name
#      matches what Testsigma reported - works for numeric-id conventions,
#      descriptive names ("Login - Zeiss"), or anything else, since it matches
#      exactly what's stored in that field, not an assumed pattern.
#   2. The reverse-lookup suite API resolves which suite(s) under ADO_PLAN_ID
#      contain that test case - no suite id list to maintain.
#   3. The Test Point in that suite is resolved and PATCHed with the outcome.
##########################################################################################################################################################
<# START USER INPUTS#>

$TESTSIGMA_TEST_PLAN_ID="5740"
$REPORT_FILE_PATH="./junit-report.xml"
$MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT=180

$ADO_ORG="testsigma"
$ADO_PROJECT="testsigma"

$TESTSIGMA_API_KEY=$env:TESTSIGMA_API_KEY_SECRET
$ADO_PAT=$env:ADO_PAT_SECRET
$ADO_PLAN_ID=425
$ADO_API_VERSION="7.1"

<# END USER INPUTS #>

$TESTSIGMA_TEST_PLAN_REST_URL="https://app.testsigma.com/api/v1/execution_results"
$TESTSIGMA_JUNIT_REPORT_URL="https://app.testsigma.com/api/v1/reports/junit"

$POLL_INTERVAL_FOR_RUN_STATUS=1
$NO_OF_POLLS=($MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT/$POLL_INTERVAL_FOR_RUN_STATUS)
$SLEEP_TIME=($POLL_INTERVAL_FOR_RUN_STATUS * 60)
$global:LOG_CONTENT=""
$global:APP_URL=""
$global:EXECUTION_STATUS=-1
$global:RUN_RESULT=""
$RUN_ID=""
$global:IS_TEST_RUN_COMPLETED=-1
$global:REPORT_DATA=$null
$PSDefaultParameterValues['Invoke-RestMethod:SkipHeaderValidation'] = $true
$PSDefaultParameterValues['Invoke-WebRequest:SkipHeaderValidation'] = $true
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}" -f $TESTSIGMA_API_KEY)))

function get_status{
    $global:RUN_RESPONSE=Invoke-RestMethod  $status_URL -Method GET -Headers @{Authorization=("Bearer {0}" -f $TESTSIGMA_API_KEY);'Accept'='application/json'} -ContentType "application/json"
    $global:EXECUTION_STATUS=$RUN_RESPONSE.status
    $global:APP_URL=$RUN_RESPONSE.app_url
    $global:RUN_RESULT=$RUN_RESPONSE.result
    Write-Host "Execution Status: $EXECUTION_STATUS  |  Result: $RUN_RESULT"
}

function checkTestPlanRunStatus{
  $global:IS_TEST_RUN_COMPLETED=0
  for($i=0; $i -le $NO_OF_POLLS;$i++){
    get_status
    Write-Host "Execution Status before going for wait: $EXECUTION_STATUS ,Status_message:"($RUN_RESPONSE.message)
    if ($EXECUTION_STATUS -eq "STATUS_IN_PROGRESS" -or $EXECUTION_STATUS -eq "STATUS_CREATED"){
      Write-Host "Sleep/Wait for $SLEEP_TIME seconds before next poll....."
      sleep $SLEEP_TIME
    }else{
      $global:IS_TEST_RUN_COMPLETED=1
      Write-Host "Automated Tests Execution completed...`nTotal script execution time:$(($i)*$SLEEP_TIME/60) minutes"
      break
    }
  }
}

function saveFinalResponseToAFile{
  if ($IS_TEST_RUN_COMPLETED -eq 0){
      $global:LOG_CONTENT="Wait time exceeded specified maximum time(MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT). Please visit below URL for Test Plan Run status.$APP_URL"
      Write-Host "LogContent:$LOG_CONTENT nResponse content:"($RUN_RESPONSE | ConvertTo-Json -Compress)
   } else {
   Write-Host "Fetching reports:$TESTSIGMA_JUNIT_REPORT_URL/$RUN_ID"
   $global:REPORT_DATA=Invoke-RestMethod  $TESTSIGMA_JUNIT_REPORT_URL/$RUN_ID -Method GET -Headers @{Authorization=("Bearer {0}" -f $TESTSIGMA_API_KEY);'Accept'='application/xml'} -ContentType "application/json"
   Write-Host "report data: $REPORT_DATA"
   $REPORT_DATA.OuterXml | Out-File $REPORT_FILE_PATH
    }
    Write-Host "Reports File::$REPORT_FILE_PATH"
}

# ==================================================================================
# Fully dynamic Azure DevOps Test Point update - no static suite/test case/point ids
# ==================================================================================

$adoHeaders = @{ Authorization = ("Bearer {0}" -f $ADO_PAT) }

function Invoke-AdoRequest {
    param([string]$Uri, [string]$Method = "Get", [string]$Body = $null, [string]$ContentType = "application/json")
    try {
        if ($Body) {
            return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $adoHeaders -Body $Body -ContentType $ContentType
        } else {
            return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $adoHeaders
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody = $null
        try { $errorBody = $_.ErrorDetails.Message } catch {}
        Write-Host "ERROR calling $Method $Uri"
        Write-Host "  Status: $statusCode"
        if ($errorBody) { Write-Host "  Body: $errorBody" }
        return $null
    }
}

function Normalize-Outcome {
    param([string]$rawOutcome)
    $map = @{
        "success" = "Passed"; "passed" = "Passed"
        "failure" = "Failed"; "failed" = "Failed"
        "aborted" = "Aborted"; "blocked" = "Blocked"
        "notexecuted" = "NotExecuted"; "notapplicable" = "NotApplicable"
        "inconclusive" = "Inconclusive"; "warning" = "Warning"
        "error" = "Error"; "timeout" = "Timeout"
    }
    if ([string]::IsNullOrWhiteSpace($rawOutcome)) { return "NotExecuted" }
    $key = $rawOutcome.ToLower().Trim()
    if ($map.ContainsKey($key)) { return $map[$key] }
    Write-Host "WARNING: Unrecognized outcome '$rawOutcome' - passing through as-is."
    return $rawOutcome
}

# Escape single quotes for safe embedding in a WIQL string literal
function Escape-WiqlString {
    param([string]$Value)
    return $Value -replace "'", "''"
}

# Resolve an ADO Test Case work item id by matching Automated Test Name exactly.
# Tries the JUnit testcase 'name' first, then 'classname' as a fallback.
function Resolve-TestCaseId {
    param([string]$Name, [string]$ClassName)

    foreach ($candidate in @($Name, $ClassName)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        $escaped = Escape-WiqlString $candidate
        $wiqlBody = @{
            query = "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType] = 'Test Case' AND [Microsoft.VSTS.TCM.AutomatedTestName] = '$escaped'"
        } | ConvertTo-Json

        $wiqlUrl = "https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/wit/wiql?api-version=$ADO_API_VERSION"
        $wiqlResponse = Invoke-AdoRequest -Uri $wiqlUrl -Method Post -Body $wiqlBody

        if ($wiqlResponse -and $wiqlResponse.workItems -and $wiqlResponse.workItems.Count -gt 0) {
            if ($wiqlResponse.workItems.Count -gt 1) {
                Write-Host "WARNING: '$candidate' matched $($wiqlResponse.workItems.Count) test cases - using the first one."
            }
            return $wiqlResponse.workItems[0].id
        }
    }
    return $null
}

# Reverse lookup: which suites (in ANY plan/project) contain this test case?
function Get-SuitesForTestCase {
    param([string]$TestCaseId)
    $url = "https://dev.azure.com/$ADO_ORG/_apis/testplan/suites?testCaseId=$TestCaseId&api-version=$ADO_API_VERSION"
    $response = Invoke-AdoRequest -Uri $url -Method Get
    if (-not $response) { return @() }
    return $response.value | Where-Object { "$($_.plan.id)" -eq "$ADO_PLAN_ID" }
}

function Get-TestCaseResultsFromJunit {
    param([xml]$JunitXml)

    $testsuiteNodes = @()
    if ($JunitXml.testsuites -and $JunitXml.testsuites.testsuite) {
        $testsuiteNodes = @($JunitXml.testsuites.testsuite)
    } elseif ($JunitXml.testsuite) {
        $testsuiteNodes = @($JunitXml.testsuite)
    }

    $results = @()
    foreach ($suite in $testsuiteNodes) {
        if (-not $suite.testcase) { continue }
        foreach ($tc in @($suite.testcase)) {
            $outcome = "Passed"
            if ($tc.failure) { $outcome = "Failed" }
            elseif ($tc.error) { $outcome = "Failed" }
            elseif ($tc.skipped) { $outcome = "NotExecuted" }

            $results += [pscustomobject]@{
                Name      = $tc.name
                ClassName = $tc.classname
                Outcome   = $outcome
            }
        }
    }
    return $results
}

function Update-AzureDevOpsTestPointsFromJunit {
    param([xml]$JunitXml)

    $testCaseResults = Get-TestCaseResultsFromJunit -JunitXml $JunitXml
    if (-not $testCaseResults -or $testCaseResults.Count -eq 0) {
        Write-Host "No test cases found in JUnit report - nothing to update."
        return
    }
    Write-Host "Parsed $($testCaseResults.Count) test case results from JUnit report."

    $suiteResultMap = @{}

    foreach ($result in $testCaseResults) {
        $testCaseId = Resolve-TestCaseId -Name $result.Name -ClassName $result.ClassName
        if (-not $testCaseId) {
            Write-Host "Skipping '$($result.Name)' - no ADO Test Case found with matching Automated Test Name."
            continue
        }
        Write-Host "Resolved '$($result.Name)' -> Test Case $testCaseId"

        $matchingSuites = Get-SuitesForTestCase -TestCaseId $testCaseId
        if (-not $matchingSuites -or $matchingSuites.Count -eq 0) {
            Write-Host "No suite found in plan $ADO_PLAN_ID for test case $testCaseId - skipping."
            continue
        }

        foreach ($suite in $matchingSuites) {
            $suiteId = $suite.id

            $testPointsUrl = "https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/testplan/Plans/$ADO_PLAN_ID/Suites/$suiteId/TestPoint?testCaseId=$testCaseId&api-version=$ADO_API_VERSION"
            $testPointsResponse = Invoke-AdoRequest -Uri $testPointsUrl -Method Get

            if (-not $testPointsResponse -or $testPointsResponse.count -eq 0) {
                Write-Host "No Test Point found for test case $testCaseId in suite $suiteId - skipping."
                continue
            }

            $testPointId = $testPointsResponse.value[0].id
            $normalizedOutcome = Normalize-Outcome -rawOutcome $result.Outcome
            $entry = @{ id = $testPointId; results = @{ outcome = $normalizedOutcome } }

            if ($null -ne $suiteResultMap["$suiteId"]) {
                $suiteResultMap["$suiteId"] += @($entry)
            } else {
                $suiteResultMap["$suiteId"] = @($entry)
            }
        }
    }

    foreach ($suiteId in $suiteResultMap.Keys) {
        $entries = $suiteResultMap[$suiteId]
        $bodyJson = $entries | ConvertTo-Json -Depth 10 -Compress
        if (-not $bodyJson.StartsWith("[") -or -not $bodyJson.EndsWith("]")) {
            $bodyJson = "[$bodyJson]"
        }

        $patchUrl = "https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/testplan/Plans/$ADO_PLAN_ID/Suites/$suiteId/TestPoint?api-version=$ADO_API_VERSION"
        Write-Host "Updating Suite $suiteId with: $bodyJson"

        $patchResponse = Invoke-AdoRequest -Uri $patchUrl -Method Patch -Body $bodyJson

        if ($patchResponse) {
            Write-Host "Suite $suiteId updated successfully:"
            foreach ($point in $patchResponse.value) {
                Write-Host "  Point $($point.id) -> outcome: $($point.results.outcome)"
            }
        } else {
            Write-Host "PATCH FAILED for suite $suiteId - see error above."
        }
    }
}

Write-Host "No of polls: $NO_OF_POLLS"
Write-Host "Polling Interval:$SLEEP_TIME"
Write-Host "Junit report file path: $REPORT_FILE_PATH"

$REQUEST_BODY='{"executionId":'+"$TESTSIGMA_TEST_PLAN_ID"+'}'
try{
$TRIGGER_RESPONSE=Invoke-RestMethod -Method POST -Headers @{Authorization=("Bearer {0}" -f $TESTSIGMA_API_KEY);'Accept'='application/json'} -ContentType 'application/json' -Body $REQUEST_BODY -uri $TESTSIGMA_TEST_PLAN_REST_URL
}catch{
 Write-Host "Code:" $_.Exception.Response.StatusCode.value__
 Write-Host "Description:" $_.Exception.Response.StatusDescription
 Write-Host "Error encountered in executing a test plan. Please check if the test plan is already in running state."
 exit 1
}

$RUN_ID=$TRIGGER_RESPONSE.id
Write-Host "Execution triggered RunID: $RUN_ID"
$status_URL = "$TESTSIGMA_TEST_PLAN_REST_URL/$RUN_ID"
Write-Host  $status_URL

checkTestPlanRunStatus
saveFinalResponseToAFile

if ($IS_TEST_RUN_COMPLETED -eq 1 -and $REPORT_DATA) {
    Update-AzureDevOpsTestPointsFromJunit -JunitXml $REPORT_DATA
} else {
    Write-Host "Skipping ADO update - test run did not complete within the wait window."
}
