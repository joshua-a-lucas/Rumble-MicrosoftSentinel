@description('Location to depoloy all resources. Leave this value as-is to inherit the location from the parent resource group.')
param location string = resourceGroup().location

@description('Name of the Azure Functions app used to ingest asset information and alerts from the Rumble API. Will be used to generate unique names for associated resources.')
@maxLength(11)
param appName string = 'Rumble'

@description('Rumble Organization API key, used to authenticate the Azure Functions app with the Rumble API when fetching asset information.')
@secure()
param rumbleAPIKey string

@description('Name of the Log Analytics workspace used by Microsoft Sentinel.')
param logAnalyticsWorkspaceName string

@description('Log Analytics workspace ID, used to authenticate the Azure Functions app with the Log Analytics API.')
param logAnalyticsWorkspaceID string

@description('Log Analytics workspace key, used to authenticate the Azure Functions app with the Log Analytics API.')
@secure()
param logAnalyticsWorkspaceKey string

// Create unique names for the storage account, hosting plan, application insights instance, function app and key vault
var storageAccountName = '${toLower(appName)}${uniqueString(resourceGroup().id)}' 
var appServicePlanName = '${appName}-${uniqueString(resourceGroup().id)}'
var appInsightsName = '${appName}-${uniqueString(resourceGroup().id)}'
var functionAppName = '${appName}-${uniqueString(resourceGroup().id)}'
var keyVaultName = '${appName}-${uniqueString(resourceGroup().id)}'

// Create the storage account
resource storageAccount 'Microsoft.Storage/storageAccounts@2021-08-01' = {
	name: storageAccountName
	location: location
	sku: {
	  name: 'Standard_LRS'
	}
	kind: 'StorageV2'
	properties: {
	  supportsHttpsTrafficOnly: true
	  encryption: {
      services: {
        file: {
          keyType: 'Account'
          enabled: true
        }
        blob: {
          keyType: 'Account'
          enabled: true
        }
      }
		keySource: 'Microsoft.Storage'
	  }
	  accessTier: 'Hot'
	  }
  }

// Create the application insights instance
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
	name: appInsightsName
	location: location
	kind: 'web'
	properties: {
		Application_Type: 'web'
		publicNetworkAccessForIngestion: 'Enabled'
		publicNetworkAccessForQuery: 'Enabled'
	}
	tags: {
		'hidden-link:/subscriptions/${subscription().id}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Web/sites/${functionAppName}': 'Resource'
	}
}

// Create the App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2021-03-01' = {
	name: appServicePlanName
	location: location
	kind: 'functionapp'
	sku: {
		name: 'Y1'
	}
	properties: {}
}

// Create the key vault and enable RBAC authorization
resource keyVault 'Microsoft.KeyVault/vaults@2021-11-01-preview' = {
	name: keyVaultName
	location: location
	properties: {
		tenantId: subscription().tenantId
		enableRbacAuthorization: true
		sku: {
			family: 'A'
			name: 'standard'
		}
	}
}

// Create the key vault secret for the Rumble Organization API key
resource rumbleApiKeySecret 'Microsoft.KeyVault/vaults/secrets@2021-11-01-preview' = {
	name: '${keyVault.name}/rumbleApiKey'
	properties: {
		value: rumbleAPIKey
	}
}

// Create the key vault secret for the Log Analytics workspace key
resource workspaceKeySecret 'Microsoft.KeyVault/vaults/secrets@2021-11-01-preview' = {
	name: '${keyVault.name}/workspaceKey'
	properties: {
		value: logAnalyticsWorkspaceKey
	}
}

// Create the Azure Functions app
resource functionApp 'Microsoft.Web/sites@2021-03-01' = {
	name: functionAppName
	location: location
	kind: 'functionapp'
	identity: {
		type: 'SystemAssigned'
	}
	properties: {
	  	serverFarmId: appServicePlan.id
		httpsOnly: true
	}
}

// Configure the Azure Functions app
resource functionAppAppsettings 'Microsoft.Web/sites/config@2018-11-01' = {
	name: '${functionAppName}/appsettings'
	properties: {
		AzureWebJobsStorage: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${listKeys(storageAccount.id, storageAccount.apiVersion).keys[0].value}'
		WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${listKeys(storageAccount.id, storageAccount.apiVersion).keys[0].value}'
		WEBSITE_CONTENTSHARE: toLower(functionAppName)
    APPINSIGHTS_INSTRUMENTATIONKEY: appInsights.properties.InstrumentationKey
		APPLICATIONINSIGHTS_CONNECTION_STRING: 'InstrumentationKey=${appInsights.properties.InstrumentationKey}'
		FUNCTIONS_WORKER_RUNTIME: 'powershell'
		FUNCTIONS_WORKER_RUNTIME_VERSION: '~7'
		FUNCTIONS_EXTENSION_VERSION: '~3'
		// Custom environment variables
		rumbleApiKey: '@Microsoft.KeyVault(SecretUri=${rumbleApiKeySecret.properties.secretUri})'
		workspaceId: logAnalyticsWorkspaceID
		workspaceKey: '@Microsoft.KeyVault(SecretUri=${workspaceKeySecret.properties.secretUri})'
		// Deploy the Azure Function app from a .zip package
    WEBSITE_RUN_FROM_PACKAGE: 'https://github.com/joshua-a-lucas/Rumble-MicrosoftSentinel/raw/main/Data%20Connectors/Rumble-FunctionApp.zip'
	}
  dependsOn: [
    keyVault
    functionApp
  ]
}

// Create a function
/*
resource assetsFunction 'Microsoft.Web/sites/functions@2020-12-01' = {
	name: '${functionApp.name}/Get-RumbleAssets'
	properties: {
		config: {
			disabled: false
			bindings: [
				{
					name: 'timer'
					type: 'timerTrigger'
					direction: 'in'
					schedule: '0 0 12 * * *'
				}
			]
		}
		files: {
			'run.ps1': loadTextContent('Data Connectors/Rumble-FunctionApp/Get-RumbleAssets/run.ps1')
		}
	}
}
*/

// Get the role definition for the Key Vaults Secrets User role
resource roleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
	scope: subscription()
	name: '4633458b-17de-408a-b874-0445c86b69e6'
}

// Grant the Azure Functions app the Key Vault Secrets User role on the key vault
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2020-10-01-preview' = {
	name: guid(keyVault.id, resourceGroup().id, roleDefinition.id)
	scope: keyVault
	properties: {
		description: 'Role required for ${functionAppName} to access secrets in ${keyVaultName}'
		principalId: functionApp.identity.principalId
		roleDefinitionId: roleDefinition.id
		principalType: 'ServicePrincipal'
	}
}

// Get the existing Log Analytics workspace used by Microsoft Sentinel
resource workspace 'Microsoft.OperationalInsights/workspaces@2021-06-01' existing = {
  name: logAnalyticsWorkspaceName
}

// Define the custom Log Analytics table names
var assetTableName = 'RumbleAssets_CL'
var alertTableName = 'RumbleAlerts_CL'

// Create the a generic UI data connector
resource dataConnector 'Microsoft.SecurityInsights/dataConnectors@2021-09-01-preview' = {
  scope: workspace
  name: 'Rumble-DataConnector'
	kind: 'GenericUI'
  properties: {
    connectorUiConfig: {
      availability: {
        isPreview: true
        status: '1'
      }
      connectivityCriteria: [
        {
          type: 'IsConnectedQuery'
          value: [
            '${assetTableName}\n| summarize LastLogReceived = max(TimeGenerated)\n| project IsConnected = LastLogReceived > ago(30d)'
          ]
        }
      ]
      //customImage: 'string' // Custom image used when displaying the connector in the Microsoft Sentinel data connectors gallery
      dataTypes: [
        {
          lastDataReceivedQuery: '${assetTableName}\n| summarize LastLogReceived = max(TimeGenerated)\n| where isnotempty(LastLogReceived)'
          name: assetTableName
        }
        {
          lastDataReceivedQuery: '${alertTableName}\n| summarize LastLogReceived = max(TimeGenerated)\n| where isnotempty(LastLogReceived)'
          name: alertTableName
        }
      ]
      descriptionMarkdown: 'The [Rumble](https://www.rumble.run/) data connector provides the ability to ingest a daily export of assets from the Rumble API, as well as alerts when new devices are detected on the network.'
      graphQueries: [
        {
          baseQuery: assetTableName
          legend: 'Rumble Assets'
          metricName: 'Total data received"'
        }
        {
          baseQuery: alertTableName
          legend: 'Rumble Alerts'
          metricName: 'Total data received"'
        }
      ]
      graphQueriesTableName: assetTableName
      instructionSteps: [
				{
          title: ''
          description: '>**Note:** The Rumble Network Discovery data connector uses [Azure Functions](https://azure.microsoft.com/pricing/details/functions/) to ingest asset information and alerts into Microsoft Sentinel, as well as [Key Vault](https://azure.microsoft.com/en-us/pricing/details/key-vault/) to securely store secrets, which may result in additional charges.'
				}
        {
          title: 'Deployment'
          description: 'Refer to the Rumble Network Discovery solution for Microsoft Sentinel [GitHub repository](https://github.com/joshua-a-lucas/Rumble-MicrosoftSentinel) for deployment instructions. You will need your Log Analytics workspace name, ID and key, as well as an Organization API key for the Rumble API.'
          instructions: [
            {
              parameters: {
                fillWith: [
									'WorkspaceId'
								]
								label: 'Log Analytics workspace ID'
              }
              type: 'CopyableLabel'
            }
            {
              parameters: {
                fillWith: [
									'PrimaryKey'
								]
								label: 'Log Analytics primary key'
              }
              type: 'CopyableLabel'
            }
          ]
        }
      ]
      permissions: {
        customs: [
          {
            description: 'A Rumble Organisation API key is required to ingest asset information. [Refer to the Rumble documentation for instructions on how to create an Organization API key](https://www.rumble.run/docs/organization-api/).'
            name: 'Rumble Organization API key'
          }
          {
            description: 'Read and Write permissions to create an Azure Functions app is required to create the data connector. [Refer to the Microsoft documentation to learn more about Azure Functions](https://docs.microsoft.com/azure/azure-functions/).'
            name: 'Azure Functions (Microsoft.Web/Sites)'
          }
        ]
        resourceProvider: [
          {
            permissionsDisplayText: 'Read and Write permissions on the Log Analytics workspace are required to enable the data connector.'
            provider: 'Microsoft.OperationalInsights/workspaces'
            providerDisplayName: 'Workspace'
            requiredPermissions: {
              delete: true
              read: true
              write: true
            }
            scope: 'Workspace'
          }
					{
            permissionsDisplayText: 'Read permissions to the Log Analytics workspace keys are required. [Refer to the Microsoft documentation to learn more about Log Analytics workspace keys](https://docs.microsoft.com/azure/azure-monitor/platform/agent-windows#obtain-workspace-id-and-key).'
            provider: 'Microsoft.OperationalInsights/workspaces'
            providerDisplayName: 'Keys'
            requiredPermissions: {
              action: true
            }
            scope: 'Workspace'
					}
        ]
      }
      publisher: 'Josh Lucas'
      sampleQueries: [
        {
          description: 'Summarize the most common asset operating systems in a pie chart'
          query: 'let LastLog=toscalar(RumbleAssets | summarize max(TimeGenerated));\nRumbleAssets\n| where TimeGenerated >= LastLog\n| where os != ""\n| summarize count() by os\n|render piechart'
        }
        {
          description: 'List all newly-discovered assets'
          query: 'RumbleAlerts\n| where event_type == "new-assets-found"\n| project TimeGenerated, detected_by, names, addresses, type, os, hw, service_count'
        }
      ]
      title: 'Rumble Network Discovery'
    }
  }
}

// Define the parser names
var assetParserName = 'RumbleAssets'
var alertParserName = 'RumbleAlerts'

// Create the Rumble assets parser
resource assetParser 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  name: assetParserName
  parent: workspace
  properties: {
    etag: '*' // Required to prevent HTTP 409 (conflict) errors when redeploying template
    category: 'Rumble'
    displayName: 'Rumble Assets Parser'
    functionAlias: assetParserName
    query: loadTextContent('Parsers/RumbleAssets.txt')
    version: 1
  }
}

// Create the Rumble alerts parser
resource alertParser 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  name: alertParserName
  parent: workspace
  properties: {
    etag: '*'
    category: 'Rumble'
    displayName: 'Rumble Alerts Parser'
    functionAlias: alertParserName
    query: loadTextContent('Parsers/RumbleAlerts.txt')
    version: 1
  }
}

// Create the 'exposed web interfaces' query
resource exposedWebInterfacesQuery 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  name: 'Rumble-ExposedWebInterfaces'
  parent: workspace
  properties: {
    etag: '*'
    category: 'Hunting Queries'
    displayName: '(Rumble) Assets with exposed web interfaces'
    query: loadTextContent('Hunting Queries/ExposedWebInterfaces.txt')
    version: 2
    tags: [
      {
        name: 'description'
        value: 'Lists all assets with exposed web interfaces using HTTP/S.'
      }
      {
        name: 'tactics'
        value: 'CommandAndControl,LateralMovement'
      }
      {
        name: 'techniques'
        value: 'T1571,T0885,T1021'
      }
    ]
  }
}

// Create the 'Windows assets without logging' query
resource windowsLoggingQuery 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  name: 'Rumble-WindowsAssetsWithoutLogging'
  parent: workspace
  properties: {
    etag: '*'
    category: 'Hunting Queries'
    displayName: '(Rumble) Windows assets without security event logging'
    query: loadTextContent('Hunting Queries/WindowsAssetsWithoutLogging.txt')
    version: 2
    tags: [
      {
        name: 'description'
        value: 'Lists all Windows assets that have not sent security event logs to Microsoft Sentinel in the last week.'
      }
      {
        name: 'tactics'
        value: 'InhibitResponseFunction'
      }
      {
        name: 'techniques'
        value: 'T0804'
      }
    ]
  }
}

// Create the workbook
resource workbook 'Microsoft.Insights/workbooks@2021-08-01' = {
  name: guid('Rumble-Workbook', resourceGroup().id)
  location: location
  kind: 'shared'
  properties: {
    category: 'sentinel'
    description: 'Workbook to visualize Rumble assetinformation such as the distribution of asset types and operating systems, the most common TCP/UDP ports and protocols, and more.'
    displayName: 'Rumble Network Discovery'
    serializedData: loadTextContent('Workbooks/workbook.json')
		sourceId: workspace.id
    version: 'Notebook/1.0'
  }
}

// Create the watchlist
resource watchlist 'Microsoft.SecurityInsights/watchlists@2021-09-01-preview' = {
  scope: workspace
  name: 'Rumble-Watchlist'
  properties: {
    contentType: 'text/csv'
    description: 'High value assets from Rumble Network Discovery'
    displayName: 'Rumble - High Value Assets'
    isDeleted: false
    itemsSearchKey: 'id'
    labels: []
    numberOfLinesToSkip: 0
    provider: 'Custom'
    rawContent: loadTextContent('Watchlists/HighValueAssets.csv')
    source: 'Local file'
    watchlistId: guid('Rumble-Watchlist', resourceGroup().id)
  }
}

// Create the 'high value asset changed' alert
resource highValueAssetAlert 'Microsoft.SecurityInsights/alertRules@2021-09-01-preview' = {
  scope: workspace
  name: 'Rumble-ChangedAssetAlert'
  kind: 'Scheduled'
  properties: {
    displayName: '(Rumble) High value network asset changed'
    description: 'Detects when a high value network asset monitored by Rumble Network Discovery has changed in some capacity at the network level (e.g. new IP address, exposed ports, etc).'
    severity: 'High'
    enabled: false
    query: loadTextContent('Analytic Rules/HighValueAssetChanged.txt')
    queryFrequency: 'PT1H'
    queryPeriod: 'PT1H'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT5H'
    suppressionEnabled: false
    tactics: [
      'Reconnaissance'
      'ResourceDevelopment'
      'CommandAndControl'
      'LateralMovement'
    ]
    /*
    techniques: [
      'T1590'
      'T1584'
      'T1571'
      'T0885'
      'T1021'
    ]
    */
    alertRuleTemplateName: null
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: true
        reopenClosedIncident: false
        lookbackDuration: 'PT4H'
        matchingMethod: 'AllEntities'
        groupByEntities: []
        groupByAlertDetails: []
        groupByCustomDetails: []
      }
    }
    eventGroupingSettings: {
      aggregationKind: 'AlertPerResult'
    }
    alertDetailsOverride: {
      alertDisplayNameFormat: '(Rumble) High value network asset changed: {{address}}'
      alertDescriptionFormat: 'Rumble Network Discovery has detected that the host at {{address}} ({{name}}) has changed as of {{TimeGenerated}}.'
      alertTacticsColumnName: null
      alertSeverityColumnName: null
    }
    customDetails: {
      ID: 'id'
    }
    entityMappings: [
      {
        entityType: 'IP'
        fieldMappings: [
          {
            identifier: 'Address'
            columnName: 'address'
          }
        ]
      }
      {
        entityType: 'Host'
        fieldMappings: [
          {
            identifier: 'HostName'
            columnName: 'name'
          }
        ]
      }
    ]
  }
}

// Create the 'new asset discovered' alert
resource newAssetAlert 'Microsoft.SecurityInsights/alertRules@2021-09-01-preview' = {
  scope: workspace
  name: 'Rumble-NewAssetAlert'
  kind: 'Scheduled'
  properties: {
    displayName: '(Rumble) New network assets discovered'
    description: 'Detects when Rumble Network Discovery has found a new device connected to the network.'
    severity: 'Medium'
    enabled: false
    query: loadTextContent('Analytic Rules/NewAssetDiscovered.txt')
    queryFrequency: 'PT1H'
    queryPeriod: 'PT1H'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT5H'
    suppressionEnabled: false
    tactics: [
      'Reconnaissance'
      'ResourceDevelopment'
      'CommandAndControl'
      'LateralMovement'
    ]
    alertRuleTemplateName: null
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: true
        reopenClosedIncident: false
        lookbackDuration: 'PT4H'
        matchingMethod: 'AnyAlert'
        groupByEntities: []
        groupByAlertDetails: []
        groupByCustomDetails: []
      }
    }
    eventGroupingSettings: {
      aggregationKind: 'SingleAlert'
    }
    alertDetailsOverride: {
      alertDisplayNameFormat: '(Rumble) New network assets discovered'
      alertDescriptionFormat: 'Rumble Network Discovery has detected new assets on the network as of {{TimeGenerated}}.'
      alertTacticsColumnName: null
      alertSeverityColumnName: null
    }
    customDetails: null
    entityMappings: [
      {
        entityType: 'IP'
        fieldMappings: [
          {
            identifier: 'Address'
            columnName: 'address'
          }
        ]
      }
      {
        entityType: 'Host'
        fieldMappings: [
          {
            identifier: 'HostName'
            columnName: 'name'
          }
        ]
      }
    ]
  }
}
