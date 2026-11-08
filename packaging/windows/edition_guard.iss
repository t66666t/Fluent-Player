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
    Result := '此文件夹包含另一个 Fluent Player 版本。请选择其他文件夹。现有文件未被更改。';
    Exit;
  end;
  if DirExists(OwnRunner) then
  begin
    Result := '该程序文件名已被一个文件夹占用。请选择其他文件夹。现有文件未被更改。';
    Exit;
  end;
  if FileExists(OwnRunner) then
  begin
    if not ReadInstalledEdition(OwnRunner, CompanyName, ProductName) then
    begin
      Result := '无法核实现有程序的身份。请选择其他文件夹。现有文件未被更改。';
      Exit;
    end;
    if (CompanyName <> '{#EditionCompany}') or (ProductName <> '{#EditionProduct}') then
    begin
      Result := '现有程序属于另一个版本或发布者。请选择其他文件夹。现有文件未被更改。';
      Exit;
    end;
  end;
end;
