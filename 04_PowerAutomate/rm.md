# Schritt 1: Prüfen ob Terraform installiert ist.
Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd.exe /c C:\\terraform-bin\\terraform.exe -version''' StandardOutput=> CommandOutputVersionCheck1 StandardError=> CommandErrorOutputVersionCheck1 ExitCode=> CommandExitCodeVersionCheck1
SET TFexe TO $'''C:\\terraform-bin\\terraform.exe'''
IF CommandExitCodeVersionCheck1 <> 0 THEN
    Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd.exe /c mkdir C:\\terraform-bin 2>nul & curl -L -o C:\\terraform-bin\\terraform.zip https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_windows_amd64.zip''' StandardOutput=> CommandOutputZIPcurl StandardError=> CommandErrorOutputZIPcurl ExitCode=> CommandExitCodeZIPcurl
    Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd.exe /c powershell -Command \"Expand-Archive -Path \'C:\\terraform-bin\\terraform.zip\' -DestinationPath \'C:\\terraform-bin\' -Force\"''' StandardOutput=> CommandOutputZIPexpand StandardError=> CommandErrorOutputZIPexpand ExitCode=> CommandExitCodeZIPexpand
    Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd.exe /c C:\\terraform-bin\\terraform.exe -version''' StandardOutput=> CommandOutputVersionCheck2 StandardError=> CommandErrorOutputVersionCheck2 ExitCode=> CommandExitCodeVersionCheck2
    IF CommandExitCodeVersionCheck2 = 0 THEN
        Display.ShowMessageDialog.ShowMessage Title: $'''Installation Status''' Message: $'''Terraform wurde erfolgreich installiert''' Icon: Display.Icon.Information Buttons: Display.Buttons.OK DefaultButton: Display.DefaultButton.Button1 IsTopMost: False ButtonPressed=> ButtonPressed
        SET TFexe TO $'''C:\\terraform-bin\\terraform.exe'''
    ELSE
        Display.ShowMessageDialog.ShowMessage Title: $'''Installation Status''' Message: $'''Terraform Installation fehlgeschlagen : %CommandErrorOutputZIPexpand%''' Icon: Display.Icon.ErrorIcon Buttons: Display.Buttons.OK DefaultButton: Display.DefaultButton.Button1 IsTopMost: False ButtonPressed=> ButtonPressed
        EXIT Code: 1 ErrorMessage: $'''Installation Fehlgeschlagen'''
    END
END
# Schritt 2: Repo-Verzeichnis abfragen (Repo liegt bereits vor)
Display.InputDialog Title: $'''Terraform Verzeichnis''' Message: $'''Pfad zum bereits vorhandenen Repo (Repo-Root)''' DefaultValue: $'''C:\\Users\\hansc\\Documents\\PW_P4''' InputType: Display.InputType.SingleLine IsTopMost: False UserInput=> TF_DIR ButtonPressed=> ButtonPressed2
SET TF_WORKDIR TO $'''%TF_DIR%\\02_Terraform'''
# Prüfen ob die Vorlage vorhanden ist
IF (File.IfFile.Exists File: $'''%TF_WORKDIR%\\terraform.tfvars.example''') THEN
ELSE
    Display.ShowMessageDialog.ShowMessage Title: $'''Repo nicht gefunden''' Message: $'''Vorlage nicht gefunden: %TF_WORKDIR%\\terraform.tfvars.example  -  Bitte prüfen, ob das Repo am angegebenen Pfad liegt.''' Icon: Display.Icon.ErrorIcon Buttons: Display.Buttons.OK DefaultButton: Display.DefaultButton.Button1 IsTopMost: False ButtonPressed=> ButtonPressed
    EXIT Code: 1 ErrorMessage: $'''Vorlage nicht gefunden'''
END
# Schritt 3: SSH-Key sicherstellen (pro PC, wird NICHT ueber Git geteilt)
File.ReadTextFromFile.ReadText File: $'''%TF_WORKDIR%\\terraform.tfvars.example''' Encoding: File.TextFileEncoding.UTF8 Content=> tfvarsExample
# Windows-Umgebungsvariable USERPROFILE in PAD-Variable holen
System.GetEnvironmentVariable.GetEnvironmentVariable Name: $'''USERPROFILE''' Value=> UserProfile
# proxmox_ssh_key_path automatisch setzen
SET proxmox_ssh_key_path TO $'''%UserProfile%\\.ssh\\id_ed25519'''
# .ssh-Ordner anlegen, falls nicht vorhanden
Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd.exe /c if not exist \"%UserProfile%\\.ssh\" mkdir \"%UserProfile%\\.ssh\"''' StandardOutput=> CommandOutputSshDir StandardError=> CommandErrorOutputSshDir ExitCode=> CommandExitCodeSshDir
# Key nur erzeugen, wenn noch KEINER existiert (Exists + ELSE)
IF (File.IfFile.Exists File: $'''%UserProfile%\\.ssh\\id_ed25519''') THEN
ELSE
    Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd.exe /c ssh-keygen -t ed25519 -f \"%UserProfile%\\.ssh\\id_ed25519\" -N \"\" -q 2>&1''' StandardOutput=> CommandOutputKeygen StandardError=> CommandErrorOutputKeygen ExitCode=> CommandExitCodeKeygen
    IF CommandExitCodeKeygen <> 0 THEN
        Display.ShowMessageDialog.ShowMessage Title: $'''SSH-Key Fehler''' Message: $'''SSH-Key konnte nicht erzeugt werden: %CommandOutputKeygen%''' Icon: Display.Icon.ErrorIcon Buttons: Display.Buttons.OK DefaultButton: Display.DefaultButton.Button1 IsTopMost: False ButtonPressed=> ButtonPressed
        EXIT Code: 1 ErrorMessage: $'''SSH-Key Erzeugung fehlgeschlagen'''
    END
END
# Public Key einlesen und anzeigen (einmalig auf Proxmox eintragen)
File.ReadTextFromFile.ReadText File: $'''%UserProfile%\\.ssh\\id_ed25519.pub''' Encoding: File.TextFileEncoding.UTF8 Content=> PublicKeyInhalt
Display.ShowMessageDialog.ShowMessage Title: $'''SSH Public Key''' Message: $'''Bitte diesen Public Key EINMALIG auf dem Proxmox-Host eintragen.
 
Auf dem Proxmox-Host ausfuehren:
mkdir -p /root/.ssh
echo \"HIER_DEN_KEY_VON_UNTEN_EINFUEGEN\" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
 
Public Key:
%PublicKeyInhalt%''' Icon: Display.Icon.Information Buttons: Display.Buttons.OK DefaultButton: Display.DefaultButton.Button1 IsTopMost: False ButtonPressed=> ButtonPressed
# Schritt 4: terraform.tfvars aus Vorlage erzeugen
# Überspringen wenn terraform.tfvars schon konfiguriert wurde
IF (File.IfFile.Exists File: $'''%TF_WORKDIR%\\terraform.tfvars''') THEN
ELSE
    File.ReadTextFromFile.ReadText File: $'''%TF_WORKDIR%\\terraform.tfvars.example''' Encoding: File.TextFileEncoding.UTF8 Content=> tfvarsExample
    Display.InputDialog Title: $'''Container ID''' Message: $'''Bitte gib eine ID für den Container an.''' DefaultValue: 201 InputType: Display.InputType.SingleLine IsTopMost: False UserInput=> acn_vm_id ButtonPressed=> ButtonPressed2
    Text.Replace.ReplaceText Text: tfvarsExample TextToFind: $'''acn_vm_id = ''' IgnoreCase: False ReplaceWith: $'''acn_vm_id = \"%acn_vm_id%\"''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> tfvarsFilled
    Display.InputDialog Title: $'''acn_root_password angeben''' Message: $'''Bitte gib ein Passwort für den Root Account des ACN''' InputType: Display.InputType.Password IsTopMost: False UserInput=> acn_root_password ButtonPressed=> ButtonPressed2
    Text.Replace.ReplaceText Text: tfvarsFilled TextToFind: $'''acn_root_password = \"\"''' IgnoreCase: False ReplaceWith: $'''acn_root_password = \"%acn_root_password%\"''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> tfvarsFilled
    Display.InputDialog Title: $'''Proxmox Endpoint''' Message: $'''Bitte Proxmox API-URL angeben (z.B. https://192.168.1.10:8006/)''' InputType: Display.InputType.SingleLine IsTopMost: False UserInput=> proxmox_api_endpoint ButtonPressed=> ButtonPressed2
    Text.Replace.ReplaceText Text: tfvarsFilled TextToFind: $'''proxmox_api_endpoint  = \"\"''' IgnoreCase: False ReplaceWith: $'''proxmox_api_endpoint  = \"%proxmox_api_endpoint%\"''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> tfvarsFilled
    Display.InputDialog Title: $'''Proxmox API Token''' Message: $'''Bitte den API Token angeben (Format: user@pve!tokenid=secret)''' InputType: Display.InputType.Password IsTopMost: False UserInput=> proxmox_api_token ButtonPressed=> ButtonPressed2
    Text.Replace.ReplaceText Text: tfvarsFilled TextToFind: $'''proxmox_api_token     = \"\"''' IgnoreCase: False ReplaceWith: $'''proxmox_api_token     = \"%proxmox_api_token%\"''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> tfvarsFilled
    Display.InputDialog Title: $'''Proxmox Node Name''' Message: $'''Bitte den Proxmox Node Namen angeben.''' InputType: Display.InputType.SingleLine IsTopMost: False UserInput=> proxmox_node_name ButtonPressed=> ButtonPressed2
    Text.Replace.ReplaceText Text: tfvarsFilled TextToFind: $'''proxmox_node_name     = \"\"''' IgnoreCase: False ReplaceWith: $'''proxmox_node_name     = \"%proxmox_node_name%\"''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> tfvarsFilled
    Display.InputDialog Title: $'''Proxmox Root Passwort''' Message: $'''Bitte das Proxmox Root Passwort angeben.''' InputType: Display.InputType.Password IsTopMost: False UserInput=> proxmox_root_password ButtonPressed=> ButtonPressed2
    Text.Replace.ReplaceText Text: tfvarsFilled TextToFind: $'''proxmox_root_password = \"\"''' IgnoreCase: False ReplaceWith: $'''proxmox_root_password = \"%proxmox_root_password%\"''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> tfvarsFilled
    Display.InputDialog Title: $'''Proxmox SSH Endpoint''' Message: $'''Bitte den SSH Endpoint (IP/Host des Proxmox) angeben.''' InputType: Display.InputType.SingleLine IsTopMost: False UserInput=> proxmox_ssh_endpoint ButtonPressed=> ButtonPressed2
    Text.Replace.ReplaceText Text: tfvarsFilled TextToFind: $'''proxmox_ssh_endpoint  = \"\"''' IgnoreCase: False ReplaceWith: $'''proxmox_ssh_endpoint  = \"%proxmox_ssh_endpoint%\"''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> tfvarsFilled
    Display.InputDialog Title: $'''Proxmox SSH Key Path''' Message: $'''Bitte den Pfad zum privaten SSH Key angeben.''' InputType: Display.InputType.SingleLine IsTopMost: False UserInput=> proxmox_ssh_key_path ButtonPressed=> ButtonPressed2
    Text.Replace.ReplaceText Text: tfvarsFilled TextToFind: $'''proxmox_ssh_key_path  = \"\"''' IgnoreCase: False ReplaceWith: $'''proxmox_ssh_key_path  = \"%proxmox_ssh_key_path%\"''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> tfvarsFilled
    File.WriteText File: $'''%TF_WORKDIR%\\terraform.tfvars''' TextToWrite: tfvarsFilled AppendNewLine: True IfFileExists: File.IfFileExists.Overwrite Encoding: File.FileEncoding.UTF8
END
# Schritt 5: inventory.yml aus Vorlage erzeugen (Ansible)
# Passe INV_DIR an, wo die inventory.yml.example liegt (z.B. %TF_DIR%\03_Ansible)
SET INV_DIR TO $'''%TF_DIR%\\03_Ansible'''
Folder.Copy Folder: $'''%INV_DIR%\\dashboard''' Destination: $'''%TF_WORKDIR%\\playbooks''' IfFolderExists: Folder.IfExists.Overwrite
File.Copy Files: $'''%INV_DIR%\\*''' Destination: $'''%TF_WORKDIR%\\playbooks''' IfFileExists: File.IfExists.Overwrite
# Überspringen wenn inventory.yml schon konfiguriert wurde
IF (File.IfFile.Exists File: $'''%TF_WORKDIR%\\playbooks\\inventory.yml''') THEN
ELSE
    File.ReadTextFromFile.ReadText File: $'''%INV_DIR%\\inventory.yml.example''' Encoding: File.TextFileEncoding.UTF8 Content=> invExample
    Display.InputDialog Title: $'''Ansible Host''' Message: $'''IP-Adresse des Proxmox Hosts angeben.''' InputType: Display.InputType.SingleLine IsTopMost: False UserInput=> ansible_host ButtonPressed=> ButtonPressedInv
    Text.Replace.ReplaceText Text: invExample TextToFind: $'''ansible_host: ''' IgnoreCase: False ReplaceWith: $'''ansible_host: %ansible_host%''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> invFilled
    Display.InputDialog Title: $'''Proxmox Node''' Message: $'''Proxmox Node Namen angeben (z.B. pve).''' InputType: Display.InputType.SingleLine IsTopMost: False UserInput=> proxmox_node ButtonPressed=> ButtonPressedInv
    Text.Replace.ReplaceText Text: invFilled TextToFind: $'''proxmox_node: ''' IgnoreCase: False ReplaceWith: $'''proxmox_node: %proxmox_node%''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> invFilled
    Display.InputDialog Title: $'''Backup Storage''' Message: $'''Backup Storage Namen angeben (z.B. local, usbBCK).''' InputType: Display.InputType.SingleLine IsTopMost: False UserInput=> backup_storage ButtonPressed=> ButtonPressedInv
    Text.Replace.ReplaceText Text: invFilled TextToFind: $'''backup_storage: ''' IgnoreCase: False ReplaceWith: $'''backup_storage: %backup_storage%''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> invFilled
    Display.InputDialog Title: $'''Proxmox API User''' Message: $'''API User angeben (z.B. ansible@pve).''' InputType: Display.InputType.SingleLine IsTopMost: False UserInput=> proxmox_api_user ButtonPressed=> ButtonPressedInv
    Text.Replace.ReplaceText Text: invFilled TextToFind: $'''proxmox_api_user: \"\"''' IgnoreCase: False ReplaceWith: $'''proxmox_api_user: \"%proxmox_api_user%\"''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> invFilled
    Display.InputDialog Title: $'''Proxmox API Token ID''' Message: $'''API Token ID angeben (z.B. ansible).''' InputType: Display.InputType.SingleLine IsTopMost: False UserInput=> proxmox_api_token_id ButtonPressed=> ButtonPressedInv
    Text.Replace.ReplaceText Text: invFilled TextToFind: $'''proxmox_api_token_id: \"\"''' IgnoreCase: False ReplaceWith: $'''proxmox_api_token_id: \"%proxmox_api_token_id%\"''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> invFilled
    Display.InputDialog Title: $'''Proxmox API Token Secret''' Message: $'''API Token Secret angeben.''' InputType: Display.InputType.Password IsTopMost: False UserInput=> proxmox_api_token_secret ButtonPressed=> ButtonPressedInv
    Text.Replace.ReplaceText Text: invFilled TextToFind: $'''proxmox_api_token_secret: \"\"''' IgnoreCase: False ReplaceWith: $'''proxmox_api_token_secret: \"%proxmox_api_token_secret%\"''' ActivateEscapeSequences: False ComparisonType: Text.TextComparisonType.Ordinal Result=> invFilled
    File.WriteText File: $'''%INV_DIR%\\inventory.yml''' TextToWrite: invFilled AppendNewLine: True IfFileExists: File.IfFileExists.Overwrite Encoding: File.FileEncoding.UTF8
END
# Schritt 4: Terraform ausführen (im Unterordner 02_Terraform)
Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd.exe /c %TFexe% init -upgrade -input=false''' WorkingDirectory: TF_WORKDIR StandardOutput=> CommandOutputTFinit StandardError=> CommandErrorOutputTFinit ExitCode=> CommandExitCodeTFinit
IF CommandExitCodeTFinit <> 0 THEN
    Display.ShowMessageDialog.ShowMessage Title: $'''Init Fehlgeschlagen''' Message: $'''Terraform init fehlgeschlagen: %CommandErrorOutputTFinit%''' Icon: Display.Icon.ErrorIcon Buttons: Display.Buttons.OK DefaultButton: Display.DefaultButton.Button1 IsTopMost: False ButtonPressed=> ButtonPressed3
    EXIT Code: 1 ErrorMessage: $'''Init Fehlgeschlagen'''
END
Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd.exe /c %TFexe% plan -input=false''' WorkingDirectory: TF_WORKDIR StandardOutput=> CommandOutputTFplan StandardError=> CommandErrorOutputTFplan ExitCode=> CommandExitCodeTFplan
IF CommandExitCodeTFplan <> 0 THEN
    Display.ShowMessageDialog.ShowMessage Title: $'''Plan Fehlgeschlagen''' Message: $'''Terraform plan fehlgeschlagen: %CommandErrorOutputTFplan%''' Icon: Display.Icon.ErrorIcon Buttons: Display.Buttons.OK DefaultButton: Display.DefaultButton.Button1 IsTopMost: False ButtonPressed=> ButtonPressed3
    EXIT Code: 1 ErrorMessage: $'''Plan Fehlgeschlagen'''
END
Display.SelectFromListDialog.SelectFromList Title: $'''Terraform Apply bestätigen''' Message: $'''Plan war erfolgreich. Änderungen jetzt anwenden?''' List: [$'''Ja''', $'''Nein'''] IsTopMost: False AllowEmpty: False SelectedItem=> ApplyConfirm SelectedIndex=> ApplyConfirmIndex ButtonPressed=> ButtonPressedApply
IF ApplyConfirm <> $'''Ja''' THEN
    Display.ShowMessageDialog.ShowMessage Title: $'''Abgebrochen''' Message: $'''Apply wurde vom Benutzer abgebrochen.''' Icon: Display.Icon.Information Buttons: Display.Buttons.OK DefaultButton: Display.DefaultButton.Button1 IsTopMost: False ButtonPressed=> ButtonPressed4
    EXIT Code: 0 ErrorMessage: $''''''
END
Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd.exe /c %TFexe% apply -auto-approve -input=false''' WorkingDirectory: TF_WORKDIR StandardOutput=> CommandOutputTFapply StandardError=> CommandErrorOutputTFapply ExitCode=> CommandExitCodeTFapply
IF CommandExitCodeTFapply <> 0 THEN
    Display.ShowMessageDialog.ShowMessage Title: $'''Apply Fehlgeschlagen''' Message: $'''Terraform apply fehlgeschlagen: %CommandErrorOutputTFapply%''' Icon: Display.Icon.ErrorIcon Buttons: Display.Buttons.OK DefaultButton: Display.DefaultButton.Button1 IsTopMost: False ButtonPressed=> ButtonPressed3
    EXIT Code: 1 ErrorMessage: $'''Apply Fehlgeschlagen'''
END
Display.ShowMessageDialog.ShowMessage Title: $'''Fertig''' Message: $'''Terraform apply erfolgreich abgeschlossen.''' Icon: Display.Icon.Information Buttons: Display.Buttons.OK DefaultButton: Display.DefaultButton.Button1 IsTopMost: False ButtonPressed=> ButtonPressed5
