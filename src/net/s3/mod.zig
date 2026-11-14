//! S3-compatible transport, with caller-supplied credentials and signing time.
pub const sigv4 = @import("sigv4.zig");
pub const transport = @import("transport.zig");
pub const client = @import("client.zig");

pub const Client = client.Client;
pub const Config = client.Config;
pub const Credentials = client.Credentials;
pub const Error = client.Error;
pub const Body = client.Body;
pub const Response = client.Response;
pub const Transport = client.Transport;
pub const HttpTransport = client.HttpTransport;
pub const Retry = client.Retry;
pub const Condition = client.Condition;
pub const PutOptions = client.PutOptions;
pub const Range = client.Range;
pub const ListOptions = client.ListOptions;
pub const ListResult = client.ListResult;
pub const Object = client.Object;
pub const CompletedPart = client.CompletedPart;
pub const Versioning = client.Versioning;
pub const MultipartOptions = client.MultipartOptions;
pub const RestoreTier = client.RestoreTier;
pub const RestoreOptions = client.RestoreOptions;
pub const RestoreState = client.RestoreState;
pub const ObjectState = client.ObjectState;
pub const objectState = client.objectState;

test {
    @import("std").testing.refAllDecls(@This());
}
