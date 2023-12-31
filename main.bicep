/*
  Purpose:
  Deploy the resources for the UI based inputs that are gathered/defined in the
  associated createUIDefinition.json.
*/

//////////////////////////////////////////////////////////////////////////////
// Parameters - start
// These are passed in from createUIDefinition.json as the template's "payload" - this is the interactive application that runs
// in the context of the Azure portal. 
// see the "outputs" section of createUIDefinition.json
//
// These can also be passed in from the command line when running with the Azure CLI (az cli)
//
// az deployment group create \
//   --name "$deployment" \
//   --resource-group "$resource_group" \
//   --template-file "$template" \
//   --parameters "$parameters" \
//   --verbose --debug
//
// where $parameters is a JSON file containing the parameters to pass in

// param subscriptionId string
// param tenantId string
// param ResourceGroup string
// param cstorvVmImageLocation string
// param cstorvVmImangeName string
// param cvuvVmImageLocation string
// param cvuvVmImageName string
// param TESTexistingVM string
// param TESTexistingNIC string
// param cclearvVmImageLocation string
// param cclearvVmImageName string
// param adminVmEnable string
// param adminVmName string
// param adminVmSize string
// param notifyEmail string

param location string

param deploymentId string
param adminUser string
param sshPublicKey string
param virtualNetwork object

param cstorvEnable bool = false
param cstorvName string
param cstorvVmSize string
param cstorvVmNumDisks int
param cstorvVmDiskSize int
param cstorvVmImageId string

param cclearvEnable bool = false
param cclearvName string = 'cClear-V'
param cclearvVmSize string = 'Standard_D4s_v5'
param cclearvVmImageId string

param lbName string
param vmssName string
param vmssVmSize string
param cvuvVmImageId string
param vmssMin int
param vmssMax int

// cvuv downstream tool IPs - must go into generated user-data
param downstreamTools string
param notifyEmail string

// Docs: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-support
param tags object

// Parameters - end
//////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////
// Variables - start

// compute the subnet IDs depending on whether they exist.
var monitoringSubnetId = virtualNetwork.newOrExisting == 'new' ? monitoringsubnet.id : resourceId(virtualNetwork.resourceGroup, 'Microsoft.Network/virtualNetworks/subnets', virtualNetwork.name, virtualNetwork.subnets.monitoringSubnet.name)

// ANDY NOTE: TODO: make sure 60 is a reasonable value - guessing between 60 and 300.
// see: https://learn.microsoft.com/en-us/azure/templates/microsoft.network/loadbalancers?pivots=deployment-language-bicep#backendaddresspoolpropertiesformat
// var lbDrainPeriodInSecs = 60
// var lbIdleTimeoutInMinutes = 5
var lbBePoolName = '${lbName}-backend'
var lbPoolId = resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, lbBePoolName)
var lbProbeName = '${lbName}-probe'
var lbProbeId = resourceId('Microsoft.Network/loadBalancers/probes', lbName, lbProbeName)

var vmssInstRepairGracePeriod = 'PT10M'
// var vmssInstRepairAction = 'Replace'

// For production deployment this should be 'Detach' so data isn't lost; 
// for testing 'Delete' works, but since we're in a resource group deleting the whole RG is probably a better approach
// var cstorvDataDiskDeleteOption = 'Delete'
var cstorvDataDiskDeleteOption = 'Detach'

// TODO: will probably need to add these to the UI and bring in as params.
var autoscaleUpThreshhold = 10000000 // 10 MBytes
var autoscaleUpTimeGrain = 'PT1M'
var autoscaleUpTimeWindow = 'PT5M'
var autoscaleUpCooldown = 'PT1M'
var autoscaleDownThreshhold = 2500000 // 2.5 MBytes
var autoscaleDownTimeGrain = 'PT1M'
var autoscaleDownTimeWindow = 'PT5M'
var autoscaleDownCooldown = 'PT1M'

var linuxConfiguration = {
  disablePasswordAuthentication: true
  ssh: {
    publicKeys: [
      {
        path: '/home/${adminUser}/.ssh/authorized_keys'
        keyData: sshPublicKey
      }
    ]
  }
}

// var cvuv_cloud_init_header = '''
// #!/bin/bash
// set -ex

// boot_config_file="/home/cpacket/boot_config.toml"
// capture_nic_ip="$(ip addr show eth0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)"
// capture_nic="eth0"

// touch "$boot_config_file"
// chmod a+w "$boot_config_file"
// cat >"$boot_config_file"  <<BOOTCONFIG
// vm_type = "azure"
// cvuv_mode = "inline"
// cvuv_mirror_eth_0 = "$capture_nic"

// '''

// var cvuv_cloud_init_footer = '''
// BOOTCONFIG
// '''

// var cvuv_cloud_init_body = '''
// cvuv_vxlan_id_0 = 1337
// cvuv_vxlan_srcip_0 = "$capture_nic_ip"
// cvuv_vxlan_remoteip_0 = "REPLACE_WITH_REMOTE_IP"
// '''

// var cvuv_cloud_init = '${cvuv_cloud_init_header}${replace(cvuv_cloud_init_body, 'REPLACE_WITH_REMOTE_IP', cVu3rdPartyToolIPs)}${cvuv_cloud_init_footer}'

// Variables - end
//////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////
// Resources - start

// Network - Vnet and monitoring network. 
// TODO: is there a way to condition on null values instead of the magic 'new' string?
resource observabilityVnet 'Microsoft.Network/virtualNetworks@2020-11-01' = if (virtualNetwork.newOrExisting == 'new') {
  name: virtualNetwork.name
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: virtualNetwork.addressPrefixes
    }
  }
  // TODO: is this the correct key for the tag?
  tags: contains(tags, 'Microsoft.Network/virtualNetworks') ? tags['Microsoft.Network/virtualNetworks'] : null
}

resource monitoringsubnet 'Microsoft.Network/virtualNetworks/subnets@2020-11-01' = if (virtualNetwork.newOrExisting == 'new') {
  name: virtualNetwork.subnets.monitoringSubnet.name
  parent: observabilityVnet
  properties: {
    addressPrefix: virtualNetwork.subnets.monitoringSubnet.addressPrefix
    networkSecurityGroup: {
      id: managementSecurityGroup.id
    }
  }
}

resource functionssubnet 'Microsoft.Network/virtualNetworks/subnets@2020-11-01' = if (virtualNetwork.newOrExisting == 'new') {
  name: virtualNetwork.subnets.functionsSubnet.name
  parent: observabilityVnet
  properties: {
    addressPrefix: virtualNetwork.subnets.functionsSubnet.addressPrefix
    // addressPrefix: cidrSubnet(virtualNetwork.addressPrefixes[0], 24, 11)
    delegations: [
      {
        name: 'Microsoft.Web.serverFarms'
        properties: {
          serviceName: 'Microsoft.Web/serverFarms'
        }
        type: 'Microsoft.Network/virtualNetworks/subnets/delegations'
      }
    ]
    privateEndpointNetworkPolicies: 'Disabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

// docs: https://learn.microsoft.com/en-us/azure/templates/microsoft.network/loadbalancers?pivots=deployment-language-bicep
resource lb 'Microsoft.Network/loadBalancers@2021-05-01' = {
  name: lbName
  location: location
  tags: contains(tags, 'Microsoft.Network/loadBalancers') ? tags['Microsoft.Network/loadBalancers'] : null
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    backendAddressPools: [
      {
        name: lbBePoolName
        // properties: {
        //   // ANDY NOTE: might want to get this in future, however at this point on my subscription
        //   // it generated a deployment error:
        //   // code: 'SubscriptionNotRegisteredForFeature'
        //   // message: 'Subscription 84a19d11-9f42-48f0-9ac9-ae0e4b9ca37f is not registered for feature Microsoft.Network/SLBAllowAdminStateChangeForConnectionDraining required to carry out the requested operation.'
        //   //drainPeriodInSeconds: lbDrainPeriodInSecs

        //   //ANDY: this generates an error at deployment time - location not valid in here - however it's in the docs!
        //   //location: location
        // }
      }
    ]
    frontendIPConfigurations: [
      {
        name: '${lbName}-frontend'
        properties: {
          subnet: {
            id: monitoringSubnetId
          }
        }
      }
    ]
    loadBalancingRules: [
      {
        name: '${lbName}-to-vmss'
        properties: {
          // ANDY NOTE TODO: verify that this combination of ports and protocol seems to check the "high availability ports" checkbox in portal
          frontendPort: 0
          backendPort: 0
          protocol: 'All'

          // ANDY NOTE TODO: might want this -- more research needed
          //idleTimeoutInMinutes: lbIdleTimeoutInMinutes

          // ANDY NOTE TODO: I believe we want this enabled
          enableTcpReset: true

          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIpConfigurations', lbName, '${lbName}-frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, lbBePoolName)
          }
          probe: {
            id: lbProbeId
          }
        }
      }
    ]
    probes: [
      {
        name: lbProbeName
        properties: {
          protocol: 'Https'
          port: 443
          requestPath: '/'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
        // Alternatively, used for testing:
        // properties: {
        //   protocol: 'Tcp'
        //   port: 443
        //   intervalInSeconds: 5
        //   numberOfProbes: 2
        // }
      }
    ]
  }
}

// cstor-v resources
// Andy note: placeholder - lifted from Jayme's code
// docs: https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/virtualmachines?pivots=deployment-language-bicep

// cstor-v capture nic resource -- for private/non-public networking
// ANDY NOTE: there seems to be an issue when creating VMs that don't have public networking/ip configs setup 
//            seems as though you have to create the nic and VM's separately see https://github.com/Azure/azure-rest-api-specs/issues/19446 
//            Also, FYI - declaring separate nic resources did resolve this error -- argh!
resource cstorcapturenic 'Microsoft.Network/networkInterfaces@2020-11-01' = if (cstorvEnable) {
  name: '${cstorvName}-cap-nic'
  location: location
  dependsOn: [
    observabilityVnet
  ]
  properties: {
    ipConfigurations: [
      {
        name: '${cstorvName}-cap-ipcfg'
        properties: {
          subnet: {
            id: monitoringSubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    enableAcceleratedNetworking: true
  }
  tags: contains(tags, 'Microsoft.Network/networkInterfaces') ? tags['Microsoft.Network/networkInterfaces'] : null
}

// cstor-v management nic resource -- for private/non-public networking
// ANDY NOTE: there seems to be an issue when creating VMs that don't have public networking/ip configs setup 
//            seems as though you have to create the nic and VM's separately see https://github.com/Azure/azure-rest-api-specs/issues/19446 
// resource cstormgmtenic 'Microsoft.Network/networkInterfaces@2020-11-01' = if (cstorvEnable) {
//   name: '${cstorvName}-mgmt-nic'
//   location: location
//   dependsOn: [
//     vnet
//   ]
//   properties: {
//     ipConfigurations: [
//       {
//         name: '${cstorvName}-mgmt-ipcfg'
//         properties: {
//           subnet: {
//             id: mgmtsubnetId
//           }
//           privateIPAllocationMethod: 'Dynamic'
//         }
//       }
//     ]
//     enableAcceleratedNetworking: true
//   }
//   tags: contains(tags, 'Microsoft.Network/networkInterfaces') ? tags['Microsoft.Network/networkInterfaces'] : null
// }

// cstor-v virtual machine
resource cstorvm 'Microsoft.Compute/virtualMachines@2021-03-01' = if (cstorvEnable) {

  // TODO: is this explicit dependency needed?
  // ANDY NOTE: I started getting errors that the vnet resource was not found
  //           I'm guessing this is because there are no references to the vnet resource in here -- the monsubnetId is a variable
  dependsOn: [
    observabilityVnet
  ]

  name: cstorvName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: cstorvVmSize
    }
    storageProfile: {
      imageReference: {
        // ANDY NOTE: this image is in one region, and you deploy to another, an error will be thrown!
        id: cstorvVmImageId
      }
      osDisk: {
        osType: 'Linux'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        // ANDY NOTE: might want to just select 'Delete' for these; but then log access is problematic..
        deleteOption: cstorvDataDiskDeleteOption
      }
      dataDisks: [for j in range(0, cstorvVmNumDisks): {
        name: '${cstorvName}-datadisk-${j}'
        lun: j
        createOption: 'Empty'
        diskSizeGB: cstorvVmDiskSize
        caching: 'ReadWrite'
        // ANDY NOTE: see notes at variable declaration above
        deleteOption: cstorvDataDiskDeleteOption
      }]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: cstorcapturenic.id
          // properties: {
          //   primary: true
          // }
        }
        // {
        //   id: cstormgmtenic.id
        //   properties: {
        //     primary: true
        //   }
        // }
      ]
    }

    osProfile: {
      computerName: cstorvName
      adminUsername: adminUser
      adminPassword: sshPublicKey
      linuxConfiguration: linuxConfiguration
      // TODO: user-data generated from bicep vars etc...
      // customData: loadFileAsBase64('./userdata-cstor.bash')
    }
  }
  tags: contains(tags, 'Microsoft.Compute/virtualMachines') ? tags['Microsoft.Compute/virtualMachines'] : null
}

resource cclearvnic 'Microsoft.Network/networkInterfaces@2020-11-01' = if (cclearvEnable) {
  name: cclearvName
  location: location
  dependsOn: [
    observabilityVnet
  ]
  properties: {
    ipConfigurations: [
      {
        name: 'management-ipcfg'
        properties: {
          subnet: {
            id: monitoringSubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    enableAcceleratedNetworking: true // Do we need this for cClear?
  }
  tags: contains(tags, 'Microsoft.Network/networkInterfaces') ? tags['Microsoft.Network/networkInterfaces'] : null
}

// docs: https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/virtualmachines?pivots=deployment-language-bicep
resource cclearvm 'Microsoft.Compute/virtualMachines@2021-03-01' = if (cclearvEnable) {
  dependsOn: [
    observabilityVnet
  ]
  name: cclearvName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: cclearvVmSize
    }
    storageProfile: {
      imageReference: {
        id: cclearvVmImageId
      }
      osDisk: {
        osType: 'Linux'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        deleteOption: 'Delete'
      }
      dataDisks: [
        {
          name: '${cclearvName}-DataDisk1'
          lun: 1
          createOption: 'Empty'
          diskSizeGB: 500
          caching: 'ReadWrite'
          deleteOption: 'Delete'
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: cclearvnic.id
        }
      ]
    }
    osProfile: {
      computerName: cclearvName
      adminUsername: adminUser
      adminPassword: sshPublicKey
      linuxConfiguration: linuxConfiguration
    }
  }
  tags: contains(tags, 'Microsoft.Compute/virtualMachines') ? union(tags['Microsoft.Compute/virtualMachines'], { 'cpacket:ApplianceType': 'cclearv' }) : { 'cpacket:ApplianceType': 'cclearv' }
}

// docs: https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/virtualmachinescalesets?pivots=deployment-language-bicep#virtualmachinescalesetproperties
// example: //example: https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/quick-create-bicep-windows?tabs=CLI
// ANDY NOTE TODO: need to review with Jake, Dwane to ensure we're using consistent settings across 
//            CLI, BICEP/UI flow and characterization tests
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2022-11-01' = {

  // ANDY NOTE: I rean into a case that seemed like a race condition; deployment failed indicating that the loadbalancer didn't exist.
  // ...so I'm adding an explicit dependency here
  // docs: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/resource-dependencies
  // ALSO NOTE: I ran this many times __without__ adding this -- so its also hard to verify directly if this actually fixed it. 
  // ...that said, adding this did not throw any errors, and I verified that it is deploying with this dependsOn block added. you're welcome. 
  dependsOn: [
    observabilityVnet
    lb
  ]

  name: vmssName
  location: location
  tags: contains(tags, 'Microsoft.Compute/virtualMachineScaleSets') ? tags['Microsoft.Compute/virtualMachineScaleSets'] : null

  sku: {
    name: vmssVmSize
    tier: 'Standard'
    capacity: vmssMin
  }

  properties: {

    //constrainedMaximumCapacity: true
    //doNotRunExtensionsOnOverprovisionedVMs: true

    //additionalCapabilities {}

    orchestrationMode: 'Uniform'

    overprovision: false

    //ANDY NOTE: need to research...
    //zoneBalance: true

    //ANDY NOTE: need to research...
    //singlePlacementGroup: true

    // docs: https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/virtualmachinescalesets?pivots=deployment-language-bicep#automaticrepairspolicy
    automaticRepairsPolicy: {
      enabled: true
      gracePeriod: vmssInstRepairGracePeriod
      // ANDY NOTE: using this value as 'Replace' throws an error saying it's invalid, docs say default is 'Replace' so leaving this 
      // commented out. 
      // repairAction: vmssInstRepairAction
    }

    // docs: https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/virtualmachinescalesets?pivots=deployment-language-bicep#scaleinpolicy
    scaleInPolicy: {

      // ANDY NOTE: in preview as of 07/17/23 apparently

      // forceDeletion: false

      rules: [
        'Default'
      ]

    }

    // ANDY NOTE: need to research...
    // spotRestorePolicy: {}

    upgradePolicy: {
      // ANDY NOTE TODO: we want to change this to Rolling - and match the settings Jake is using in CLI
      mode: 'Manual'

      // ANDY NOTE: need to research more - discus with Jake/Martin
      // automaticOSUpgradePolicy: {}
      // rollingUpgradePolicy: {}

    }

    virtualMachineProfile: {

      osProfile: {
        computerNamePrefix: '${deploymentId}-cvuv-'
        adminUsername: adminUser
        adminPassword: sshPublicKey
        linuxConfiguration: linuxConfiguration // TODO: workaround for https://github.com/Azure/bicep/issues/449

        // ANDY NOTE TODO: not doing it this way as it requires to be run by CLI vs via Azure UI flow
        // Needs to be generated above and passed in as a string variable
        // customData: loadFileAsBase64('./cvuv-userdata.bash')
      }

      storageProfile: {

        // imageReference docs: https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/virtualmachinescalesets?pivots=deployment-language-bicep#imagereference
        // ANDY NOTE: generic test with ubuntu
        // get these field details from this command : az vm image list --output table --publisher Canonical --all
        // imageReference: {
        //   publisher: 'Canonical'
        //   offer: '0001-com-ubuntu-server-jammy'
        //   sku: '22_04-lts'
        //   version: 'latest'
        // }

        // this uses the cvuv image from params!
        imageReference: {
          // ANDY NOTE: if this image id is pointing to an image in another subscription an error will be thrown if "image sharing" is not enabled..
          // ANDY NOTE: this this image is in one region, and you deploy to another, an error will be thrown!
          id: cvuvVmImageId
        }

        osDisk: {
          createOption: 'FromImage'

          // ANDY NOTE: this will throw and error saying this cannot be configured for VMSS
          //           this is listed in the documentation as a valid option - so unclear why it throws an error..
          // deleteOption: 'Delete'

          // ANDY NOTE: leaving as a placeholder in case we want to experiment with larger osDisks at this level
          // diskSizeGB: 80

          osType: 'Linux'
        }

        // ANDY NOTE: data disks not required by cvuv currently
        // dataDisks: {}
      }

      networkProfile: {
        healthProbe: {
          //ANDY NOTE: should be able to use the same health probe as the LB (as per discussion / observations with Dwane)
          id: lbProbeId
        }

        networkInterfaceConfigurations: [
          {
            name: '${deploymentId}-cvuv-cap-nic'

            properties: {
              primary: true
              enableAcceleratedNetworking: true
              enableIPForwarding: true
              ipConfigurations: [
                {
                  name: '${deploymentId}-cap-ipcfg'
                  properties: {
                    subnet: {
                      id: monitoringSubnetId
                    }
                    loadBalancerBackendAddressPools: [
                      {
                        id: lbPoolId
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]

      }

    }

  }
}

// docs: https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/autoscalesettings?pivots=deployment-language-bicep
// example: https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/quick-create-bicep-windows?tabs=CLI
// ANDY NOTE: replicating most of Dwane's terraform settings in the following two terraform files
//  https://github.com/cPacketNetworks/ccloud-cli/blob/46f4e7134db8f3f206321873f0e4cf54cbb3fe09/azure/scale.set.lb.tf/main.tf#L391
//  https://github.com/cPacketNetworks/ccloud-cli/blob/46f4e7134db8f3f206321873f0e4cf54cbb3fe09/azure/scale.set.lb.tf/variables.tf#L133
resource vmssautoscalesettings 'Microsoft.Insights/autoscalesettings@2021-05-01-preview' = {
  name: '${deploymentId}-autoscale'
  location: location
  //ANDY NOTE: using the *same* tags we used for the scale sets above
  tags: contains(tags, 'Microsoft.Compute/virtualMachineScaleSets') ? tags['Microsoft.Compute/virtualMachineScaleSets'] : null

  properties: {
    //ANDY NOTE: an error is thrown if this name is not the same as the resource name above ...weird :)
    name: '${deploymentId}-autoscale'
    targetResourceUri: vmss.id
    enabled: true
    profiles: [
      {
        name: '${deploymentId}-net-scale-prof'
        capacity: {
          minimum: string(vmssMin)
          maximum: string(vmssMax)
          default: string(vmssMin)
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Network in Total'
              metricResourceUri: vmss.id
              timeGrain: autoscaleUpTimeGrain
              statistic: 'Average'
              timeWindow: autoscaleUpTimeWindow
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: autoscaleUpThreshhold
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: autoscaleUpCooldown
            }
          }
          {
            metricTrigger: {
              metricName: 'Network in Total'
              metricResourceUri: vmss.id
              timeGrain: autoscaleDownTimeGrain
              statistic: 'Average'
              timeWindow: autoscaleDownTimeWindow
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: autoscaleDownThreshhold
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: autoscaleDownCooldown
            }
          }
        ]
      }
    ]
  }
}

resource managementSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-02-01' = {
  name: 'managementSecurityGroup'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-ssh'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'allow-https'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

// @description('Specifies the name of the key vault.')
// param keyVaultName string = 'ccloud'
// 
// @description('Specifies whether Azure Virtual Machines are permitted to retrieve certificates stored as secrets from the key vault.')
// param enabledForDeployment bool = false
// 
// @description('Specifies whether Azure Disk Encryption is permitted to retrieve secrets from the vault and unwrap keys.')
// param enabledForDiskEncryption bool = false
// 
// @description('Specifies whether Azure Resource Manager is permitted to retrieve secrets from the key vault.')
// param enabledForTemplateDeployment bool = false
// 
// @description('Specifies the Azure Active Directory tenant ID that should be used for authenticating requests to the key vault. Get it by using Get-AzSubscription cmdlet.')
// param tenantId string = tenant().tenantId
// 
// @description('Specifies the object ID of a user, service principal or security group in the Azure Active Directory tenant for the vault. The object ID must be unique for the list of access policies. Get it by using Get-AzADUser or Get-AzADServicePrincipal cmdlets.')
// param objectId string
// 
// @description('Specifies the permissions to keys in the vault. Valid values are: all, encrypt, decrypt, wrapKey, unwrapKey, sign, verify, get, list, create, update, import, delete, backup, restore, recover, and purge.')
// param keysPermissions array = [
//   'list'
// ]
// 
// @description('Specifies the permissions to secrets in the vault. Valid values are: all, get, list, set, delete, backup, restore, recover, and purge.')
// param secretsPermissions array = [
//   'list'
//   'get'
//   'set'
// ]
// 
// @description('Specifies whether the key vault is a standard vault or a premium vault.')
// @allowed([
//   'standard'
//   'premium'
// ])
// param skuName string = 'standard'
// 
// @description('Specifies the name of the secret that you want to create.')
// param secretName string = 'cpacket'
// 
// @description('Specifies the value of the secret that you want to create.')
// @secure()
// param secretValue string
// 
// resource ccloudKeyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
//   name: 'cpacket'
//   location: location
//   // tags: {}
//   properties: {
//     sku: {
//       family: 'A'
//       name: 'standard'
//     }
//     tenantId: tenant().tenantId
//     // accessPolicies: []
//     // enabledForDeployment: false
//     // enabledForDiskEncryption: false
//     // enabledForTemplateDeployment: false
//     // enableSoftDelete: true
//     // softDeleteRetentionInDays: 90
//     // enableRbacAuthorization: true
//     // vaultUri: 'https://cpacket2.vault.azure.net/'
//     // provisioningState: 'Succeeded'
//     // publicNetworkAccess: 'Enabled'
//   }
// }
//
// resource kv 'Microsoft.KeyVault/vaults@2021-11-01-preview' = {
//   name: keyVaultName
//   location: location
//   properties: {
//     enabledForDeployment: enabledForDeployment
//     enabledForDiskEncryption: enabledForDiskEncryption
//     enabledForTemplateDeployment: enabledForTemplateDeployment
//     tenantId: tenantId
//     enableSoftDelete: true
//     softDeleteRetentionInDays: 1
//     accessPolicies: [
//       {
//         objectId: objectId
//         tenantId: tenantId
//         permissions: {
//           keys: keysPermissions
//           secrets: secretsPermissions
//         }
//       }
//     ]
//     sku: {
//       name: skuName
//       family: 'A'
//     }
//     networkAcls: {
//       defaultAction: 'Allow'
//       bypass: 'AzureServices'
//     }
//   }
// }
// 
// resource secret 'Microsoft.KeyVault/vaults/secrets@2021-11-01-preview' = {
//   parent: kv
//   name: secretName
//   properties: {
//     value: secretValue
//   }
// }

// Service plan

resource hostplan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: 'test2814'
  kind: 'elastic'
  location: location
  properties: {
    // serverFarmId: 14883
    // name: 'test2814'
    // workerSize: 'D1'
    // workerSizeId: 3
    // currentWorkerSize: 'D1'
    // currentWorkerSizeId: 3
    // currentNumberOfWorkers: 1
    // webSpace: 'mbright-bicep-test-EastUS2webspace-Linux'
    // planName: 'VirtualDedicatedPlan'
    // computeMode: 'Dynamic' // or 'Dedicated'?
    perSiteScaling: false
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 1
    isSpot: false
    // kind: 'elastic'
    reserved: true
    isXenon: false
    hyperV: false
    // mdmId: 'waws-prod-bn1-205_14883'
    targetWorkerCount: 0
    targetWorkerSizeId: 0
    zoneRedundant: false
  }
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
    size: 'EP1'
    family: 'EP'
    capacity: 1
  }
}

// Storage account

resource test2814Storage 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  name: 'test2814'
  location: location
  tags: {}
  properties: {
    minimumTlsVersion: 'TLS1_0'
    allowBlobPublicAccess: true
    networkAcls: {
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: []
      defaultAction: 'Allow'
    }
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

// Insights

resource test2814Monitoring 'Microsoft.Insights/components@2020-02-02' = {
  name: 'test2814'
  location: location
  tags: {}
  kind: 'web'
  // etag: '"0700b04b-0000-0200-0000-64c15d2f0000"'
  properties: {
    Application_Type: 'web'
    Request_Source: 'rest'
    RetentionInDays: 90
    // Retention: 'P90D'
    IngestionMode: 'ApplicationInsights'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    // Ver: 'v2'
  }
}

// Event Grid System Topic

resource vmssevents 'Microsoft.EventGrid/systemTopics@2022-06-15' = {
  properties: {
    source: resourceGroup().id
    topicType: 'Microsoft.Resources.ResourceGroups'
  }
  identity: {
    type: 'None'
  }
  location: 'global'
  tags: {}
  name: 'vmss-events'
}

resource scaling 'Microsoft.EventGrid/eventSubscriptions@2023-06-01-preview' = {
  properties: {
    destination: {
      properties: {
        resourceId: applianceregistration.id
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
      endpointType: 'AzureFunction'
    }
    filter: {
      subjectBeginsWith: ''
      subjectEndsWith: ''
      includedEventTypes: [
        'Microsoft.Resources.ResourceWriteSuccess'
        'Microsoft.Resources.ResourceWriteFailure'
        'Microsoft.Resources.ResourceWriteCancel'
        'Microsoft.Resources.ResourceDeleteSuccess'
        'Microsoft.Resources.ResourceDeleteFailure'
        'Microsoft.Resources.ResourceDeleteCancel'
        'Microsoft.Resources.ResourceActionSuccess'
        'Microsoft.Resources.ResourceActionFailure'
        'Microsoft.Resources.ResourceActionCancel'
      ]
      enableAdvancedFilteringOnArrays: true
    }
    labels: [
      'functions-applianceregistration'
    ]
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
  name: 'scaling'
}

resource test2814 'Microsoft.Web/sites@2022-09-01' = {
  name: 'test2814'
  kind: 'functionapp,linux,container,azurecontainerapps'
  location: location
  properties: {
    // name: 'test2814'
    // webSpace: '64e7982ed98384de391cfad3e94d0efd4660b324261577e2ed054464a6d968e9'
    // contentAvailabilityState: 'Normal'
    // runtimeAvailabilityState: 'Normal'
    siteConfig: {
      linuxFxVersion: 'DOCKER|mbrightcpacket/registerappliances:0.0.2'
      functionAppScaleLimit: 30
      minimumElasticInstanceCount: 0
    }
    // deploymentId: 'test2814'
    // kind: 'functionapp,linux,container,azurecontainerapps'
    managedEnvironmentId: test2814ManagedEnv.id
    // tags: {
    //   'hidden-link: /app-insights-resource-id': '/subscriptions/93004638-8c6b-4e33-ba58-946afd57efdf/resourceGroups/mbright-bicep-test/providers/microsoft.insights/components/test2814'
    //   'hidden-link: /app-insights-instrumentation-key': 'b32a8026-6079-400f-a315-d68a3b4a4aad'
    //   'hidden-link: /app-insights-conn-string': 'InstrumentationKey=b32a8026-6079-400f-a315-d68a3b4a4aad;IngestionEndpoint=https://eastus2-4.in.applicationinsights.azure.com/;LiveEndpoint=https://eastus2.livediagnostics.monitor.azure.com/'
    // }
    // privateEndpointConnections: []
    storageAccountRequired: false
  }
  identity: {
    type: 'None'
  }
}

resource applianceregistration 'Microsoft.Web/sites/functions@2022-09-01' = {
  parent: test2814
  name: 'applianceregistration'
  properties: {
    // name: 'applianceregistration'
    // script_root_path_href: 'http://test2814.graybay-04fc09de.eastus2.azurecontainerapps.io/admin/vfs/home/site/wwwroot/applianceregistration/'
    // script_href: 'http://test2814.graybay-04fc09de.eastus2.azurecontainerapps.io/admin/vfs/home/site/wwwroot/applianceregistration/__init__.py'
    // config_href: 'http://test2814.graybay-04fc09de.eastus2.azurecontainerapps.io/admin/vfs/home/site/wwwroot/applianceregistration/function.json'
    // test_data_href: 'http://test2814.graybay-04fc09de.eastus2.azurecontainerapps.io/admin/vfs/tmp/FunctionsData/applianceregistration.dat'
    // href: 'http://test2814.graybay-04fc09de.eastus2.azurecontainerapps.io/admin/functions/applianceregistration'
    config: {
      scriptFile: '__init__.py'
      bindings: [
        {
          type: 'eventGridTrigger'
          name: 'event'
          direction: 'in'
        }
      ]
    }
    // test_data: ''
    language: 'python'
    isDisabled: false
  }
}

resource test2814ManagedEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: 'test2814'
  location: location
  properties: {
    // appLogsConfiguration: {
    //   destination: 'log-analytics'
    //   logAnalyticsConfiguration: {
    //     customerId: '1fbbc6d6-fc9e-4884-ba43-fe825530484b'
    //   }
    // }
    zoneRedundant: false
    // kedaConfiguration: {}
    // daprConfiguration: {}
    // customDomainConfiguration: {}
    // peerAuthentication: {
    //   mtls: {
    //     enabled: false
    //   }
    // }
  }
}
