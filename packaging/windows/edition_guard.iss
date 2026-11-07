; Runtime guard, including /SILENT and /VERYSILENT installations.
; Never deletes, renames, or automatically changes the selected directory.
[Code]
function ReadInstalledEdition(const Filename: String; var CompanyName, ProductName: String): Boolean;
var
  ShellObject, ParentFolder, FileItem: Variant;
begin
  Result := False;
  CompanyName := '';
  ProductName := '';
  try
    ShellObject := CreateOleObject('Shell.Application');
    ParentFolder := ShellObject.NameSpace(ExtractFileDir(Filename));
    FileItem := ParentFolder.ParseName(ExtractFileName(Filename));
    CompanyName := FileItem.ExtendedProperty('System.Company');
    ProductName := FileItem.ExtendedProperty('System.Software.ProductName');
    Result := (CompanyName <> '') and (ProductName <> '');
  except
    // Unreadable or missing identity is not permission to overwrite a file.
    Result := False;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  OwnRunner, OtherRunner, CompanyName, ProductName: String;
begin
  Result := '';
  OwnRunner := ExpandConstant('{app}\{#EditionRunner}');
  OtherRunner := ExpandConstant('{app}\{#OtherEditionRunner}');
  if FileExists(OtherRunner) or DirExists(OtherRunner) then
  begin
    Result := 'This folder contains another Fluent Player edition. Please choose a different folder. Existing files have not been changed.';
    Exit;
  end;
  if DirExists(OwnRunner) then
  begin
    Result := 'The application filename is already used by a directory. Please choose a different folder. Existing files have not been changed.';
    Exit;
  end;
  if FileExists(OwnRunner) then
  begin
    if not ReadInstalledEdition(OwnRunner, CompanyName, ProductName) then
    begin
      Result := 'The existing application identity could not be verified. Please choose a different folder. Existing files have not been changed.';
      Exit;
    end;
    if (CompanyName <> '{#EditionCompany}') or (ProductName <> '{#EditionProduct}') then
    begin
      Result := 'The existing application belongs to another edition or publisher. Please choose a different folder. Existing files have not been changed.';
      Exit;
    end;
  end;
end;
