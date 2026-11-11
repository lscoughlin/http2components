{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, test, alert, client authentication
notes:
  - This test checks peer alert details without provider-native error codes.
---
}
unit Http2.Test.Tls.AlertContract;
{$mode delphi}{$H+}{$interfaces com}
interface
uses Http2.Common.Tls.Context;
procedure RequireTlsClientAuthAlert(const AContext: ITLSContext;
  const AExpectedAlert: Integer; const ARequireRequestEvidence: Boolean = True);
implementation
uses SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Policy,
  Http2.Common.Tls.Session;

procedure RequireTlsClientAuthAlert(const AContext: ITLSContext;
  const AExpectedAlert: Integer; const ARequireRequestEvidence: Boolean);
var
  Client, Server: ITLSSession;
  CO: TTlsClientSessionOptions;
  SO: TTlsServerSessionOptions;
  CToS, SToC, Buffer: TBytes;
  ClientFailed, ServerFailed, Requested: Boolean;
  ClientAlert, ServerAlert, I: Integer;
  Started: QWord;

  procedure Observe(const E: ETlsSessionError; const AClient: Boolean);
  begin
    if AClient then
    begin
      ClientFailed := True;
      ClientAlert := E.PeerAlertDescription;
      Requested := E.ClientCertificateRequested;
    end
    else
    begin
      ServerFailed := True;
      ServerAlert := E.PeerAlertDescription;
    end;
  end;

  procedure Transfer(const Source, Destination: ITLSSession;
    var Pending: TBytes; const ToClient: Boolean);
  var N: SizeInt;
  begin
    if Length(Pending) = 0 then
    begin
      SetLength(Pending, TlsMaxEncryptedInput);
      N := Source.DrainEncrypted(Pending, 0, Length(Pending));
      SetLength(Pending, N);
    end;
    if (Length(Pending) = 0) or (Destination.State = tssFailed) then Exit;
    try
      N := Destination.FeedEncrypted(Pending, 0, Length(Pending));
      Delete(Pending, 0, N);
    except on E: ETlsSessionError do Observe(E, ToClient); end;
  end;

begin
  Started := GetTickCount64;
  CO := Default(TTlsClientSessionOptions).WithAlpns(['h2']);
  CO.HostName := 'localhost';
  CO.IdentitySelection := tisExplicit;
  CO.HandshakeStartMs := Started;
  SO := Default(TTlsServerSessionOptions).WithAlpns(['h2']);
  SO.HandshakeStartMs := Started;
  Client := AContext.CreateClientSession(CO);
  Server := AContext.CreateServerSession(SO);
  ClientFailed := False;
  ServerFailed := False;
  Requested := False;
  ClientAlert := -1;
  ServerAlert := -1;
  try
    for I := 1 to 2048 do
    begin
      if GetTickCount64 - Started > 4000 then
        raise Exception.Create('client authentication alert test exceeded four seconds');
      if not ClientFailed then
        try Client.Advance(GetTickCount64);
        except on E: ETlsSessionError do Observe(E, True); end;
      if not ServerFailed then
        try Server.Advance(GetTickCount64);
        except on E: ETlsSessionError do Observe(E, False); end;
      Transfer(Client, Server, CToS, False);
      Transfer(Server, Client, SToC, True);
      if ClientFailed and ServerFailed then Break;
    end;
    if not (ClientFailed and ServerFailed and
      (Requested or not ARequireRequestEvidence) and
      (ClientAlert = AExpectedAlert) and (ServerAlert = -1)) then
      raise Exception.CreateFmt(
        'client auth alert: client=%d server=%d requested=%d alert=%d expected=%d local-peer-alert=%d',
        [Ord(ClientFailed), Ord(ServerFailed), Ord(Requested), ClientAlert,
         AExpectedAlert, ServerAlert]);
    SetLength(Buffer, 1);
    for I := 1 to 2 do
    begin
      try
        Client.ReadPlaintext(Buffer, 0, 1);
        raise Exception.Create('failed TLS read did not repeat its peer alert');
      except
        on E: ETlsSessionError do
          if (E.PeerAlertDescription <> AExpectedAlert) or
             (ARequireRequestEvidence and not E.ClientCertificateRequested) then
            raise Exception.Create('repeated TLS failure lost peer alert details');
      end;
    end;
  finally
    Client.Abort;
    Server.Abort;
  end;
end;
end.
